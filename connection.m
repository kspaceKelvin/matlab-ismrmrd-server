classdef connection < handle
    properties
        tcpHandle
        log
        savedata
        savedataFile
        savedataFolder
        savedataGroup
        mrdFilePath
        dset
    end

    methods
        % ----------------------------------------------------------------------
        %      TCP/IP connection handling functions
        % ----------------------------------------------------------------------
        function obj = connection(tcpHandle, log, savedata, savedataFile, savedataFolder, savedataGroup)
            if (nargin < 3)
                savedata = false;
            end
            if (nargin < 4)
                savedataFile = '';
            end

            if (nargin < 5)
                savedataFolder = '';
            end

            if (nargin < 6)
                savedataGroup = 'dataset';
            end

            obj.tcpHandle      = tcpHandle;
            obj.log            = log;
            obj.savedata       = savedata;
            obj.savedataFile   = savedataFile;
            obj.savedataFolder = savedataFolder;
            obj.savedataGroup  = savedataGroup;
        end

        function create_save_file(obj)
            if (obj.savedata)
                % Create savedata folder, if necessary
                if ~isempty(obj.savedataFolder) && ~exist(obj.savedataFolder, 'dir')
                    mkdir(obj.savedataFolder)
                    obj.log.info("Created folder %s to save incoming data", obj.savedataFolder)
                end

                if (~isempty(obj.savedataFile))
                    obj.mrdFilePath = obj.savedataFile;
                else
                    obj.mrdFilePath = fullfile(obj.savedataFolder, strcat('MRD_input_', datestr(now,'yyyy-mm-dd-HHMMSS'), '_', num2str(randi(100)), '.h5'));
                end

                % Create HDF5 file to store incoming MRD data
                obj.log.info("Incoming data will be saved to: '%s' in group '%s'", obj.mrdFilePath, obj.savedataGroup)
                obj.dset = ismrmrd.Dataset(obj.mrdFilePath, obj.savedataGroup);
            end
        end

        function out = read(obj,length)
            if (length == 0)
                out = [];
                return
            end
            out = uint8(read(obj.tcpHandle, double(length), 'uint8'))';
        end

        function obj = write(obj,bytes)
            fwrite(obj.tcpHandle, bytes, class(bytes));
        end

        function [out,obj] = next(obj)
            identifier = read_mrd_message_identifier(obj);

            if isempty(identifier)
                throw(MException('connection:nodata', "Failed to read data"))
            end

            switch identifier
                case constants.MRD_MESSAGE_CONFIG_FILE
                    out = read_config_file(obj);
                case constants.MRD_MESSAGE_CONFIG_TEXT
                    out = read_config_text(obj);
                case constants.MRD_MESSAGE_METADATA_XML_TEXT
                    out = read_metadata(obj);
                case constants.MRD_MESSAGE_CLOSE
                    out = read_close(obj);
                case constants.MRD_MESSAGE_ISMRMRD_ACQUISITION
                    out = read_acquisition(obj);
                case constants.MRD_MESSAGE_ISMRMRD_WAVEFORM
                    out = read_waveform(obj);
                case constants.MRD_MESSAGE_ISMRMRD_IMAGE
                    out = read_image(obj);
                otherwise
                    out = unknown_message_identifier(obj, identifier);
            end
        end

        function out = unknown_message_identifier(obj, identifier)
            obj.log.error("Received unknown message type: %d", double(identifier));
            out = [];
        end

        function identifier = read_mrd_message_identifier(obj)
            identifier_bytes = read(obj,constants.SIZEOF_MRD_MESSAGE_IDENTIFIER);
            identifier = typecast(identifier_bytes,'uint16');
        end

        % ----- MRD_MESSAGE_CONFIG_FILE (1) ------------------------------------
        % This message contains the file name of a configuration file used for 
        % image reconstruction/post-processing.  The file must exist on the server.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Config file name (1024 bytes, char          )
        % ----------------------------------------------------------------------
        function send_config_file(obj, filename)
            obj.log.info("--> Sending MRD_MESSAGE_CONFIG_FILE (1)")
            if (numel(filename) > constants.SIZEOF_MRD_MESSAGE_CONFIGURATION_FILE)
                error("Config file name exceeds maximum allowed length of %d", constants.SIZEOF_MRD_MESSAGE_CONFIGURATION_FILE)
            end

            ID  = typecast(uint16(constants.MRD_MESSAGE_CONFIG_FILE),       'uint8');
            msg = zeros(1, constants.SIZEOF_MRD_MESSAGE_CONFIGURATION_FILE, 'uint8');
            msg(1:numel(filename)) = uint8(filename);

            write(obj, ID);
            write(obj, msg);
        end

        function config_file = read_config_file(obj)
            obj.log.info("<-- Received MRD_MESSAGE_CONFIG_FILE (1)")
            config_file_bytes = read(obj,constants.SIZEOF_MRD_MESSAGE_CONFIGURATION_FILE);
            config_file = strtok(char(config_file_bytes)', char(0));

            if strcmpi(config_file, "savedataonly")
                obj.log.info("Save data, but no processing based on config")
                if (obj.savedata)
                    obj.log.debug("Saving data is already enabled")
                else
                    obj.savedata = true;
                    obj.create_save_file();
                end
            end

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.log.debug("    Saving config_file to file")
                obj.dset.writetext(config_file, strcat(obj.dset.grouppath, '/', 'config_file'));
            end
        end

        % ----- MRD_MESSAGE_CONFIG_TEXT (2) ------------------------------------
        % This message contains the configuration information (text contents) used 
        % for image reconstruction/post-processing.  Text is null-terminated.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Length           (   4 bytes, uint32_t      )
        %   Config text data (  variable, char          )
        % ----------------------------------------------------------------------
        function send_config_text(obj, contents)
            obj.log.info("--> Sending MRD_MESSAGE_CONFIG_TEXT (2)")

            ID  = typecast(uint16(constants.MRD_MESSAGE_CONFIG_TEXT), 'uint8');
            len = typecast(uint32(numel(contents) + 1),               'uint8');
            msg = uint8(cat(2, reshape(contents, 1, []), 0));

            write(obj, ID);
            write(obj, len);
            write(obj, msg);
        end

        function config_text = read_config_text(obj)
            obj.log.info("<-- Received MRD_MESSAGE_CONFIG_TEXT (2)")
            length = typecast(read(obj,constants.SIZEOF_MRD_MESSAGE_LENGTH), 'uint32');
            config_text_bytes = read(obj, length);
            config_text = strtok(char(config_text_bytes)', char(0));

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.log.debug("    Saving config to file")
                obj.dset.writetext(config_text, strcat(obj.dset.grouppath, '/', 'config'));
            end
        end

        % ----- MRD_MESSAGE_METADATA_XML_TEXT (3) ------------------------------
        % This message contains the metadata for the entire dataset, formatted as
        % MRD XML flexible data header text.  Text is null-terminated.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Length           (   4 bytes, uint32_t      )
        %   Text xml data    (  variable, char          )
        % ----------------------------------------------------------------------
        function send_metadata(obj, contents)
            obj.log.info("--> Sending MRD_MESSAGE_METADATA_XML_TEXT (3)")

            ID  = typecast(uint16(constants.MRD_MESSAGE_METADATA_XML_TEXT), 'uint8');
            len = typecast(uint32(numel(contents) + 1),                     'uint8');
            msg = uint8(cat(2, reshape(contents, 1, []), 0));

            write(obj, ID);
            write(obj, len);
            write(obj, msg);
        end

        function metadata = read_metadata(obj)
            disp("<-- Received MRD_MESSAGE_METADATA_XML_TEXT (3)")

            length = typecast(read(obj,constants.SIZEOF_MRD_MESSAGE_LENGTH), 'uint32');
            metadata_bytes = read(obj, length);
            metadata = strtok(char(metadata_bytes)', char(0));

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.log.debug("    Saving XML header to file")
                obj.dset.writexml(metadata);
            end

        end

        % ----- MRD_MESSAGE_CLOSE (4) ------------------------------------------
        % This message signals that all data has been sent (either from server or client).
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        % ----------------------------------------------------------------------
        function send_close(obj)
            obj.log.info("--> Sending MRD_MESSAGE_CLOSE (4)")
            write(obj, typecast(uint16(constants.MRD_MESSAGE_CLOSE), 'uint8'));
        end

        function out = read_close(obj)
            obj.log.info("<-- Received MRD_MESSAGE_CLOSE (4)")
            out = [];

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.log.debug("    Closing file %s", obj.mrdFilePath)
                obj.dset.close();
                obj.dset = [];
            end
        end

        % ----- MRD_MESSAGE_TEXT (5) -------------------------------------------
        % This message contains the arbitrary text data.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Length           (   4 bytes, uint32_t      )
        %   Text data        (  variable, char          )
        % ----------------------------------------------------------------------
        function send_text(obj, contents)
            obj.log.info("--> Sending MRD_MESSAGE_TEXT (5)")

            ID  = typecast(uint16(constants.MRD_MESSAGE_TEXT), 'uint8');
            len = typecast(uint32(numel(contents) + 1),        'uint8');
            msg = uint8(cat(2, reshape(contents, 1, []), 0));

            write(obj, ID);
            write(obj, len);
            write(obj, msg);
        end

        function txt = read_text(obj)
            obj.log.info("<-- Received MRD_MESSAGE_TEXT (5)")
            length = typecast(read(obj,constants.SIZEOF_MRD_MESSAGE_LENGTH), 'uint32');
            txt_bytes = read(obj, length);
            txt = strtok(char(txt_bytes)', char(0));
        end

        % ----- MRD_MESSAGE_ISMRMRD_ACQUISITION (1008) -------------------------
        % This message contains raw k-space data from a single readout.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Fixed header     ( 340 bytes, mixed         )
        %   Trajectory       (  variable, float         )
        %   Raw k-space data (  variable, float         )
        % ----------------------------------------------------------------------
        function send_acquisition(obj, acq)
            obj.log.info("--> Sending MRD_MESSAGE_ISMRMRD_ACQUISITION (1008)")

            ID  = typecast(uint16(constants.MRD_MESSAGE_ISMRMRD_ACQUISITION), 'uint8');
            header_bytes = acq.head.serialize();
            traj_bytes   = acq.traj;
            data_bytes   = acq.serializeData(); % Convert from complex to real/imag single pairs

            write(obj, ID);
            write(obj, header_bytes);
            write(obj, typecast(traj_bytes, 'uint8'));
            write(obj, typecast(data_bytes, 'uint8'));
        end

        function out = read_acquisition(obj)
            % obj.log.info("--> Received MRD_MESSAGE_ISMRMRD_ACQUISITION (1008)")
            header_bytes = read(obj,constants.SIZEOF_MRD_ACQUISITION_HEADER);
            header = ismrmrd.AcquisitionHeader(header_bytes);

            trajectory_bytes = read(obj, header.number_of_samples * header.trajectory_dimensions * 4);
            traj = typecast(trajectory_bytes','single');

            data_bytes = read(obj, uint64(header.number_of_samples) * uint64(header.active_channels) * 8);
            data = typecast(data_bytes,'single');
            data = complex(data(1:2:end), data(2:2:end));

            out = ismrmrd.Acquisition(header, traj, data);

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.dset.appendAcquisition(out);
            end
        end

        % ----- MRD_MESSAGE_ISMRMRD_IMAGE (1022) -------------------------------
        % This message contains raw k-space data from a single readout.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Fixed header     ( 198 bytes, mixed         )
        %   Attribute length (   8 bytes, uint_64       )
        %   Attribute data   (  variable, char          )
        %   Image data       (  variable, variable      )
        % ----------------------------------------------------------------------
        function obj = send_image(obj,image)
            if ~iscell(image)
                image = {image};
            end
            obj.log.info("--> Sending MRD_MESSAGE_ISMRMRD_IMAGE (1022) (%d images)", numel(image))

            for iImg = 1:numel(image)
                ID = typecast(uint16(constants.MRD_MESSAGE_ISMRMRD_IMAGE),'uint8');
                write(obj, ID);
                write(obj, image{iImg}.head.serialize());
                write(obj, typecast(uint64(image{iImg}.head.attribute_string_len), 'uint8'));  % This is not a typo -- the value is stored as uint32 in ImageHeader but sent as a uint64 here
                write(obj, uint8(image{iImg}.attribute_string));
                if isreal(image{iImg}.data)
                    write(obj, typecast(reshape(image{iImg}.data,[],1)       , 'uint8'));
                else
                    % typecast doesn't support complex data -- manually pack as real/imag pairs
                    write(obj, typecast(reshape([reshape(real(image{iImg}.data), 1, []); reshape(imag(image{iImg}.data), 1, [])], [], 1), 'uint8'));
                end
            end
        end

        function image = read_image(obj)
            obj.log.info("<-- Received MRD_MESSAGE_ISMRMRD_IMAGE (1022)")

            obj.log.debug("   Reading in %d bytes of image header", constants.SIZEOF_MRD_IMAGE_HEADER)
            header_bytes = read(obj,constants.SIZEOF_MRD_IMAGE_HEADER);
            header = ismrmrd.ImageHeader(uint8(header_bytes));

            attrib_length = typecast(read(obj,constants.SIZEOF_MRD_MESSAGE_ATTRIB_LENGTH), 'uint64');
            obj.log.debug("   Reading in %d bytes of attributes", attrib_length)
            attribs = char(read(obj, attrib_length))';
            obj.log.debug("   Attributes: %s", attribs)

            obj.log.debug("   Image is size %d x %d x %d with %d channels of type %s", header.matrix_size(1), header.matrix_size(2), header.matrix_size(3), header.channels, ismrmrd.ImageHeader.getMrdDatatypeName(header.data_type))
            npixels = prod(uint64(header.matrix_size)) * uint64(header.channels);
            nbytes = npixels * header.getDatatypeSize(header.data_type);

            obj.log.debug("   Reading in %d bytes of image data", nbytes)
            data_bytes = read(obj, nbytes);

            image = ismrmrd.Image(header);
            image.attribute_string = attribs;
            image = image.deserializeImageData(data_bytes);

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.dset.appendImage(sprintf('images_%d', image.image_series_index), out);
            end
        end

        % ----- MRD_MESSAGE_ISMRMRD_WAVEFORM (1026) ----------------------------
        % This message contains abitrary (e.g. physio) waveform data.
        % Message consists of:
        %   ID               (   2 bytes, unsigned short)
        %   Fixed header     (  40 bytes, mixed         )
        %   Waveform data    (  variable, uint32_t      )
        % ----------------------------------------------------------------------
        function obj = send_waveform(obj, waveform)
            obj.log.info("--> Sending MRD_MESSAGE_ISMRMRD_WAVEFORM (1026) (%d waveforms)", numel(waveform.head.version))

            headBytes = waveform.head.toBytes();
            for iWav = 1:numel(waveform.head.version)
                ID = typecast(uint16(constants.MRD_MESSAGE_ISMRMRD_WAVEFORM),'uint8');
                write(obj, ID);
                write(obj, headBytes(:,iWav));
                write(obj, typecast(reshape(waveform.data{iWav},[],1), 'uint8'));
            end
        end

        function waveform = read_waveform(obj)
            % obj.log.info("<-- Received MRD_MESSAGE_ISMRMRD_WAVEFORM (1026)")

            % obj.log.debug("   Reading in %d bytes of waveform header", constants.SIZEOF_MRD_WAVEFORM_HEADER)
            header_bytes = read(obj,constants.SIZEOF_MRD_WAVEFORM_HEADER);
            header = ismrmrd.WaveformHeader(uint8(header_bytes));
    
            % obj.log.debug("   Waveform is %d samples with %d channels", header.number_of_samples, header.channels)
            nbytes = header.number_of_samples * header.channels * 4; % 4 bytes for each uint32

            % obj.log.debug("   Reading in %d bytes of waveform data", nbytes)
            data_bytes = read(obj, nbytes);

            waveform = ismrmrd.Waveform(header, data_bytes);

            if (obj.savedata)
                if isempty(obj.dset)
                    obj.create_save_file()
                end
                obj.dset.appendWaveform(waveform);
            end
        end

    end
end
