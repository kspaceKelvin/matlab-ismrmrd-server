classdef invertcontrast < handle
    % Linting warning suppression:
    %#ok<*INUSD>  Input argument '' might be unused.  If this is OK, consider replacing it by ~
    %#ok<*NASGU>  The value assigned to variable '' might be unused.
    %#ok<*INUSL>  Input argument '' might be unused, although a later one is used.  Ronsider replacing it by ~
    %#ok<*AGROW>  The variable '' appear to change in size on every loop  iteration. Consider preallocating for speed.

    methods
        function process(obj, connection, config, metadata, logging)
            % Metadata should be MRD formatted header, but may be a string
            % if it failed conversion earlier
            try
                logging.info("Incoming dataset contains %d encodings", numel(metadata.encoding))
                logging.info("First encoding is of type '%s', with field of view of (%g x %g x %g)mm^3, matrix size of (%g x %g x %g), and %g coils", ...
                    metadata.encoding(1).trajectory, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.x, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.y, ...
                    metadata.encoding(1).encodedSpace.fieldOfView_mm.z, ...
                    metadata.encoding(1).encodedSpace.matrixSize.x, ...
                    metadata.encoding(1).encodedSpace.matrixSize.y, ...
                    metadata.encoding(1).encodedSpace.matrixSize.z, ...
                    metadata.acquisitionSystemInformation.receiverChannels)
            catch
                logging.info("Improperly formatted metadata: \n%s", metadata)
            end

            % Continuously parse incoming data parsed from MRD messages
            acqGroup = cell(1,0); % ismrmrd.Acquisition;
            imgGroup = cell(1,0); % ismrmrd.Image;
            try
                while true
                    item = next(connection);

                    % ----------------------------------------------------------
                    % Raw k-space data messages
                    % ----------------------------------------------------------
                    if isa(item, 'ismrmrd.Acquisition')
                        % Accumulate all imaging readouts in a group
                        if (~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_NOISE_MEASUREMENT)    && ...
                            ~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_PHASECORR_DATA)       && ...
                            ~item.head.flagIsSet(item.head.FLAGS.ACQ_IS_PARALLEL_CALIBRATION)       )
                                acqGroup{end+1} = item;
                        end

                        % When this criteria is met, run process_raw() on the accumulated
                        % data, which returns images that are sent back to the client.
                        if item.head.flagIsSet(item.head.FLAGS.ACQ_LAST_IN_SLICE)
                            logging.info("Processing a group of k-space data")
                            image = obj.process_raw(acqGroup, config, metadata, logging);
                            logging.debug("Sending image to client")
                            connection.send_image(image);
                            acqGroup = {};
                        end

                    % ----------------------------------------------------------
                    % Image data messages
                    % ----------------------------------------------------------
                    elseif isa(item, 'ismrmrd.Image')
                        % Only process magnitude images -- send phase images back without modification
                        if (item.head.image_type == item.head.IMAGE_TYPE.MAGNITUDE)
                            imgGroup{end+1} = item;
                        else
                            connection.send_image(item);
                            continue
                        end

                        % When this criteria is met, run process_group() on the accumulated
                        % data, which returns images that are sent back to the client.
                        % TODO: logic for grouping images
                        if false
                            logging.info("Processing a group of images")
                            image = obj.process_images(imgGroup, config, metadata, logging);
                            logging.debug("Sending image to client")
                            connection.send_image(image);
                            imgGroup = cell(1,0);
                        end

                    elseif isempty(item)
                        break;

                    else
                        logging.error("Unhandled data type: %s", class(item))
                    end
                end
            catch ME
                logging.error(sprintf('%s\nError in %s (%s) (line %d)', ME.message, ME.stack(1).('name'), ME.stack(1).('file'), ME.stack(1).('line')));
            end

            % Process any remaining groups of raw or image data.  This can 
            % happen if the trigger condition for these groups are not met.
            % This is also a fallback for handling image data, as the last
            % image in a series is typically not separately flagged.
            if ~isempty(acqGroup)
                logging.info("Processing a group of k-space data (untriggered)")
                image = obj.process_raw(acqGroup, config, metadata, logging);
                logging.debug("Sending image to client")
                connection.send_image(image);
                acqGroup = cell(1,0);
            end

            if ~isempty(imgGroup)
                logging.info("Processing a group of images (untriggered)")
                image = obj.process_images(imgGroup, config, metadata, logging);
                logging.debug("Sending image to client")
                connection.send_image(image);
                imgGroup = cell(1,0);
            end

            connection.send_close();
            return
        end

        function image = process_raw(obj, group, config, metadata, logging)
            % This function assumes that the set of raw data belongs to a 
            % single image.  If there's >1 phases, echos, sets, etc., then
            % either the call to this function from process() needs to be
            % adjusted or this code must be modified.

            % Format data into a single [RO PE cha] array
            ksp = cell2mat(permute(cellfun(@(x) x.data, group, 'UniformOutput', false), [1 3 2]));
            ksp = permute(ksp, [1 3 2]);

            % Fourier Transform
            img = fftshift(fft2(ifftshift(ksp)));

            % Sum of squares coil combination
            img = sqrt(sum(abs(img).^2,3));

            % Remove phase oversampling
            img = img(round(size(img,1)/4+1):round(size(img,1)*3/4),:);
            logging.debug("Image data is size %d x %d after coil combine and phase oversampling removal", size(img))
        
            % Normalize and convert to short (int16)
            img = img .* (32767./max(img(:)));
            img = int16(round(img));

            % Create MRD Image object, set image data and (matrix_size, channels, and data_type) in header
            image = ismrmrd.Image(img);

            % Find the center k-space index
            kspace_encode_step_1 = cellfun(@(x) x.head.idx.kspace_encode_step_1, group);
            centerLin            = cellfun(@(x) x.head.idx.user(6),              group);
            centerIdx = find(kspace_encode_step_1 == centerLin, 1);

            % Copy the relevant AcquisitionHeader fields to ImageHeader
            image.head = image.head.fromAcqHead(group{centerIdx}.head);

            % field_of_view is mandatory
            image.head.field_of_view  = single([metadata.encoding(1).reconSpace.fieldOfView_mm.x ...
                                                metadata.encoding(1).reconSpace.fieldOfView_mm.y ...
                                                metadata.encoding(1).reconSpace.fieldOfView_mm.z]);

            % Set ISMRMRD Meta Attributes
            meta = struct;
            meta.DataRole               = 'Image';
            meta.ImageProcessingHistory = 'MATLAB';
            meta.WindowCenter           = uint16(16384);
            meta.WindowWidth            = uint16(32768);
            meta.ImageRowDir            = group{centerIdx}.head.read_dir;
            meta.ImageColumnDir         = group{centerIdx}.head.phase_dir;

            % set_attribute_string also updates attribute_string_len
            image = image.set_attribute_string(ismrmrd.Meta.serialize(meta));

            % Call process_image to do actual image inversion
            image = obj.process_images({image});
        end

        function images = process_images(obj, group, config, metadata, logging)
            % Extract image data
            cData = cellfun(@(x) x.data, group, 'UniformOutput', false);
            data = cat(3, cData{:});

            % Normalize and convert to short (int16)
            data = data .* (32767./max(data(:)));
            data = int16(round(data));

            % Invert image contrast
            data = int16(abs(32767-data));

            % Re-slice back into 2D MRD images
            images = cell(1, size(data,3));
            for iImg = 1:size(data,3)
                % Create MRD Image object, set image data and (matrix_size, channels, and data_type) in header
                image = ismrmrd.Image(data(:,:,iImg));

                % Copy original image header, but keep the new data_type and channels
                newHead = image.head;
                image.head = group{iImg}.head;
                image.head.data_type = newHead.data_type;
                image.head.channels  = newHead.channels;

                % Add to ImageProcessingHistory
                meta = ismrmrd.Meta.deserialize(group{iImg}.attribute_string);
                meta = ismrmrd.Meta.appendValue(meta, 'ImageProcessingHistory', 'INVERT');
                image = image.set_attribute_string(ismrmrd.Meta.serialize(meta));

                images{iImg} = image;
            end
        end
    end
end
