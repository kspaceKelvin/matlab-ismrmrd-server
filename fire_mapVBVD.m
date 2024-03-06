classdef fire_mapVBVD < handle
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
            wavGroup = cell(1,0); % ismrmrd.Waveform;
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
                        if item.head.flagIsSet(item.head.FLAGS.ACQ_LAST_IN_MEASUREMENT)
                            logging.info("Processing a group of k-space data")
                            image = obj.process_raw(acqGroup, config, metadata, logging);
                            logging.debug("Sending image to client")
                            connection.send_image(image);
                            acqGroup = [];
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

                    % ----------------------------------------------------------
                    % Waveform data messages
                    % ----------------------------------------------------------
                    elseif isa(item, 'ismrmrd.Waveform')
                        wavGroup{end+1} = item;

                    elseif isempty(item)
                        break;

                    else
                        logging.error("Unhandled data type: %s", class(item))
                    end
                end
            catch ME
                logging.error(sprintf('%s\nError in %s (%s) (line %d)', ME.message, ME.stack(1).('name'), ME.stack(1).('file'), ME.stack(1).('line')));
            end

            % Extract raw ECG waveform data. Basic sorting to make sure that data 
            % is time-ordered, but no additional checking for missing data.
            % ecgData has shape (5 x timepoints)
            if ~isempty(wavGroup)
                isEcg   = cellfun(@(x) (x.head.waveform_id == 0), wavGroup);
                ecgTime = cellfun(@(x) x.head.time_stamp, wavGroup(isEcg));

                [~, sortedInds] = sort(ecgTime);
                indsEcg = find(isEcg);
                ecgData = cell2mat(permute(cellfun(@(x) x.data, wavGroup(indsEcg(sortedInds)), 'UniformOutput', false), [2 1]));
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
                image = obj.process_image(imgGroup, config, metadata, logging);
                logging.debug("Sending image to client")
                connection.send_image(image);
                imgGroup = cell(1,0);
            end

            connection.send_close();
            return
        end

        % Process a set of raw k-space data and return an image
        function images = process_raw(obj, group, config, metadata, logging)
            images = cell(1,0);

            % This is almost like the twix_obj
            twix_obj = twix_map_obj_fire;
            twix_obj.setMrdAcq(group);

            kspAll = twix_obj.imageData();
            logging.info("Data is 'mapVBVD formatted' with dimensions:")  % Data is 'mapVBVD formatted' with dimensions:
            logging.info(sprintf('%s ', twix_obj.dataDims{1:10}))         % Col Cha Lin Par Sli Ave Phs Eco Rep Set
            logging.info(sprintf('%3d ', size(kspAll)))                   % 404  14 124   1   1   1   1   1   1  11

            for iSli = 1:twix_obj.NSli
                for iAve = 1:twix_obj.NAve
                    for iPhs = 1:twix_obj.NPhs
                        for iEco = 1:twix_obj.NEco
                            for iRep = 1:twix_obj.NRep
                                for iSet = 1:twix_obj.NSet
                                    % Extract only one slice/average/phs, etc. at a time
                                    ksp = kspAll(:,:,:,:,iSli,iAve,iPhs,iEco,iRep,iSet);

                                    % Format data into a single [RO PE cha] array
                                    ksp = permute(ksp, [1 3 2]);

                                    % Pad array to match intended recon space (properly account for phase resolution, partial Fourier, asymmetric echo, etc. later)
                                    ksp(metadata.encoding(1).reconSpace.matrixSize.x*2, metadata.encoding(1).reconSpace.matrixSize.y,:) = 0;

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

                                    % Invert image contrast
                                    img = int16(abs(32767-img));

                                    % Format as ISMRMRD image data
                                    image = ismrmrd.Image(img);

                                    % Find the center k-space index
                                    centerIdx = find((twix_obj.Lin == twix_obj.centerLin) & (twix_obj.Sli == iSli), 1);

                                    if isempty(centerIdx)
                                        warning('Could not find center k-space readout')
                                        centerIdx = 1;
                                    end

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

                                    images{end+1} = image;
                                end
                            end
                        end
                    end
                end
            end
            logging.info(sprintf('Reconstructed %d images', numel(images)))
        end

        % Placeholder function that returns images without modification
        function images = process_images(obj, group, config, metadata, logging)
            images = group;
        end
    end
end
