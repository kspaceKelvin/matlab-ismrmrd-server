classdef WaveformHeader
    % Class for the MRD WaveformHeader data structure as described in:
    % https://ismrmrd.github.io/apidocs/1.4.2/struct_i_s_m_r_m_r_d_1_1_i_s_m_r_m_r_d___waveform_header.html
    %
    % A series of "set" functions should be used whenever possible in order to
    % ensure valid data type and size for each parameter.  These functions are
    % intentionally not part of the set handlers to improve performance when a
    % large amount of pre-validated data is being converted.
    %
    % serialize() and deserialize() functions are provided to convert this data
    % structure to/from a byte string used during streaming/networking.

    properties
        version            = zeros(1,1,'uint16');  % Version number
        flags              = zeros(1,1,'uint64');  % Bit field with flags
        measurement_uid    = zeros(1,1,'uint32');  % Unique ID for the waveform measurement
        scan_counter       = zeros(1,1,'uint32');  % Number of the acquisition after this waveform
        time_stamp         = zeros(1,1,'uint32');  % Timestamp at the start of the waveform
        number_of_samples  = zeros(1,1,'uint16');  % Number of samples acquired
        channels           = zeros(1,1,'uint16');  % Active channels
        sample_time_us     = zeros(1,1,'single');  % Time between samples in microseconds
        waveform_id        = zeros(1,1,'uint16');  % ID matching the types specified in the MRD XML header
    end

    methods (Static)
        % Helper function to validate the size of inputs before setting properties
        function isValid = ValidateSize(val, sz, name)
            isValid = (ismatrix(val)) && all(size(val) == sz);
            if ~isValid
                error('%s must be shape [%s]', name, num2str(sz));
            end
        end
    end % methods (Static)

    methods
        % Constructor
        function obj = WaveformHeader(arg)
            switch nargin
                case 0
                    % Empty header
                case 1
                    if isa(arg,'ismrmrd.WaveformHeader')
                        % Already formatted WaveformHeader object
                        obj = arg;
                    elseif isa(arg,'uint8')
                        % Byte array (e.g. from serialized data)
                        obj = deserialize(obj,arg);
                    else
                        % Unknown type
                        error('Unsupported constructor with input class %s', class(arg))
                    end
                otherwise
                    error('Constructor must have 0 or 1 arguments.')
            end
        end

        % Set handlers for each property to ensure correct type and size
        % Ideally, these would be the actual set handler (e.g. set.version())
        % so the size/type is strictly enforced, but MATLAB has a significant
        % performance overhead for set handlers.  The deserialize() function
        % should bypass these for performance reasons when receiving large
        % amounts of data.  In all other cases, these functions should be used
        % via the Acquisition class to prevent inadvertent errors.
        function obj = set_version(          obj, val),  if obj.ValidateSize(val, [1  1], 'version'),           obj.version           = uint16(val); end,  end
        function obj = set_flags(            obj, val),  if obj.ValidateSize(val, [1  1], 'flags'),             obj.flags             = uint64(val); end,  end
        function obj = set_measurement_uid(  obj, val),  if obj.ValidateSize(val, [1  1], 'measurement_uid'),   obj.measurement_uid   = uint32(val); end,  end
        function obj = set_scan_counter(     obj, val),  if obj.ValidateSize(val, [1  1], 'scan_counter'),      obj.scan_counter      = uint32(val); end,  end
        function obj = set_time_stamp(       obj, val),  if obj.ValidateSize(val, [1  1], 'time_stamp'),        obj.time_stamp        = uint32(val); end,  end
        function obj = set_number_of_samples(obj, val),  if obj.ValidateSize(val, [1  1], 'number_of_samples'), obj.number_of_samples = uint16(val); end,  end
        function obj = set_channels(         obj, val),  if obj.ValidateSize(val, [1  1], 'channels'),          obj.channels          = uint16(val); end,  end
        function obj = set_sample_time_us(   obj, val),  if obj.ValidateSize(val, [1  1], 'sample_time_us'),    obj.sample_time_us    = single(val); end,  end
        function obj = set_waveform_id(      obj, val),  if obj.ValidateSize(val, [1  1], 'waveform_id'),       obj.waveform_id       = uint16(val); end,  end

        % Convert from the byte array of the C-struct memory layout for an ISMRMRD WaveformHeader
        function obj = deserialize(obj, bytes)
            if (numel(bytes) ~= 40)
                error('Serialized WaveformHeader is %d bytes -- should be 40', numel(bytes))
            end
            obj.version           = typecast(bytes( 1: 2), 'uint16');  % First unsigned int indicates the version %
            obj.flags             = typecast(bytes( 9:16), 'uint64');  % bit field with flags %
            obj.measurement_uid   = typecast(bytes(17:20), 'uint32');  % Unique ID for the measurement %
            obj.scan_counter      = typecast(bytes(21:24), 'uint32');  % Current acquisition number in the measurement %
            obj.time_stamp        = typecast(bytes(25:28), 'uint32');  % Acquisition clock %
            obj.number_of_samples = typecast(bytes(29:30), 'uint16');  % Number of samples acquired %
            obj.channels          = typecast(bytes(31:32), 'uint16');  % Available channels%
            obj.sample_time_us    = typecast(bytes(33:36), 'single');  % Sample time in micro seconds %
            obj.waveform_id       = typecast(bytes(37:38), 'uint16');  % Waveform ID %
            % 2 bytes of additional padding after waveform_id
        end

        % Convert to the byte array of the C-struct memory layout for an ISMRMRD WaveformHeader
        function bytes = serialize(obj)
            % Convert to an ISMRMRD WaveformHeader to a byte array
            % This conforms to the memory layout of the C-struct

            bytes = cat(2, typecast(obj.version               ,'uint8'), ...
                            typecast(obj.flags                 ,'uint8'), ...
                            typecast(obj.measurement_uid       ,'uint8'), ...
                            typecast(obj.scan_counter          ,'uint8'), ...
                            typecast(obj.time_stamp            ,'uint8'), ...
                            typecast(obj.number_of_samples     ,'uint8'), ...
                            typecast(obj.channels              ,'uint8'), ...
                            typecast(obj.sample_time_us        ,'uint8'), ...
                            typecast(obj.waveform_id           ,'uint8'), ...
                            zeros(1,2                          ,'uint8'));
                            % 2 bytes of additional padding after waveform_id

            if (numel(bytes) ~= 40)
                error('Serialized WaveformHeader is %d bytes instead of 40 bytes', numel(bytes));
            end
        end

        % Check if a flag is set to true
        % Input can be a bit index or a name listed in ismrmrd.WaveformHeader.FLAGS
        function ret = flagIsSet(obj, flag)
            if isa(flag, 'char')
                b = obj.FLAGS.(flag);
            elseif (flag>0)
                b = uint64(flag);
            else
                error('Flag must be a ismrmrd.WaveformHeader.FLAGS char or a bit index.'); 
            end

            ret = bitget(obj.flags, b);
        end

        % Set a flag to true
        % Input can be a bit index or a name listed in ismrmrd.WaveformHeader.FLAGS
        function obj = flagSet(obj, flag)
            if isa(flag, 'char')
                b = obj.FLAGS.(flag);
            elseif (flag>0)
                b = uint64(flag);
            else
                error('Flag must be a ismrmrd.WaveformHeader.FLAGS char or a bit index.'); 
            end

            obj.flags = bitset(obj.flags, b);
        end

        % Set a flag to false
        % Input can be a bit index or a name listed in ismrmrd.WaveformHeader.FLAGS
        function obj = flagClear(obj, flag)
            if isa(flag, 'char')
                b = obj.FLAGS.(flag);
            elseif (flag>0)
                b = uint64(flag);
            else
                error('Flag must be a ismrmrd.WaveformHeader.FLAGS char or a bit index.'); 
            end

            obj.flags = bitset(obj.flags, b, 0);
        end

        % Clear all flags
        function obj = flagClearAll(obj)
            obj.flags = zeros(1, 1,'uint64');
        end

        % Convert to basic struct
        % This is used by built-in HDF5 functions.  Overloaded from the built-in
        % struct(obj) function to avoid warnings, but may be modified in the future
        function s = struct(obj)
            publicProperties = properties(obj);
            s = struct();
            for fi = 1:numel(publicProperties)
                s.(publicProperties{fi}) = obj.(publicProperties{fi}); 
            end
        end
    end
end
