classdef Meta
    methods (Static)
        % Take a struct and turn it in to XML-formatted MetaAttribute text.
        % Each struct field comprises a "meta" attribute with a "name" equal to
        % its field name and a "value" equal to its field value.  Numeric or cell
        % arrays are supported.
        function xml = serialize(s)
            docNode = javaObject('org.apache.xerces.dom.DocumentImpl');
            docNode.appendChild (docNode.createElement('ismrmrdMeta'));
            docRootNode = docNode.getDocumentElement;

            fields = fieldnames(s);

            for iField = 1:numel(fields)
                if ~isempty(fields{iField})
                    % Flag to discard this MetaAttribute if it contains invalid values
                    isGood = true;

                    val = s.(fields{iField});

                    if isempty(val)
                        continue
                    end

                    metaNode = docNode.createElement('meta');
                    nameNode = docNode.createElement('name');
                    nameNode.appendChild(docNode.createTextNode(fields{iField}));
                    metaNode.appendChild(nameNode);

                    % Turn scalars and numerical arrays into cell arrays
                    if ~iscell(val)
                        if ~isscalar(val) && ~ischar(val)
                            val = num2cell(val);
                        else
                            val = {val};
                        end
                    end

                    for iVal = 1:numel(val)
                        valueNode = docNode.createElement('value');
                        % chars are stored directly
                        if ischar(val{iVal})
                            valueNode.appendChild(docNode.createTextNode(val{iVal}));

                        % logicals are stored as 'true' or 'false'
                        elseif islogical(val{iVal})
                            if val{iVal}
                                valueNode.appendChild(docNode.createTextNode('true'));
                            else
                                valueNode.appendChild(docNode.createTextNode('false'));
                            end

                        % integers are stored without decimals
                        elseif isinteger(val{iVal})
                            valueNode.appendChild(docNode.createTextNode(int2str(val{iVal})));

                        % all other numerics (double/singles) are stored with 16 decimals
                        elseif isnumeric(val{iVal})
                            valueNode.appendChild(docNode.createTextNode(num2str(val{iVal}, ' %.16f')));

                        else
                            warning('Unsupported class of type %s for Meta field %s', class(val{iVal}), fields{iField})
                            isGood = false;
                            continue
                        end
                        metaNode.appendChild(valueNode);
                    end
                    if isGood
                        docRootNode.appendChild(metaNode);
                    end
                end
            end
            xml = char(xmlwrite(docNode));
        end

        % Take XML-formatted MetaAttribute text and create a MATLAB struct.
        % Each struct field name is the MetaAttribute name, with the values
        % converted to appropriate data types in arrays if appropriate.
        function metaStruct = deserialize(metaXml)
            metaStruct = struct;
        
            % Prepare Java XML parser
            docBuilder = javaMethod('newDocumentBuilder', javaMethod('newInstance','javax.xml.parsers.DocumentBuilderFactory'));
            inSrc      = javaObject('org.xml.sax.InputSource');
            strRead    = javaObject('java.io.StringReader', metaXml);
        
            javaMethod('setCharacterStream', inSrc, strRead);
            dom = javaMethod('parse', docBuilder, inSrc);
            rootNode = dom.getDocumentElement();
        
            if ~strcmp(rootNode.getNodeName(), 'ismrmrdMeta')
                warning('Root node is not named ''ismrmrdMeta''')
            end
        
            metas = rootNode.getElementsByTagName('meta');
            for iMetas = 0:metas.getLength()-1
                % Parse each MetaAttribute, which have a name and one or more value elements, e.g.
                %   <meta>
                %       <name>ImageProcessingHistory</name>
                %       <value>MATLAB</value>
                %       <value>FIRE</value>
                %   </meta>
                meta = metas.item(iMetas);
                name = char(meta.getElementsByTagName('name').item(0).getTextContent());
        
                values = meta.getElementsByTagName('value');
                cVals = cell(1,values.getLength());
                for iVal = 0:values.getLength()-1
                    cVals{iVal+1} = char(values.item(iVal).getTextContent());
                end
        
                metaStruct.(name) = cVals;
            end
        
            % Simplify struct:
            % - Convert values to bools, doubles, and ints where appropriate
            % - Single values don't need to be cell arrays
            % - Use regular arrays for multiple numbers
            fields = fieldnames(metaStruct);
            for iField = 1:numel(fields)
                values = metaStruct.(fields{iField});
                for iVal = 1:numel(values)
                    % Booleans
                    if strcmpi(values{iVal}, 'true')
                        values{iVal} = true;
                    elseif strcmpi(values{iVal}, 'false')
                        values{iVal} = false;
                    end

                    % Just numbers or negatives
                    if all(((uint8(values{iVal}) >= uint8('0')) & (uint8(values{iVal}) <= uint8('9'))) | (uint8(values{iVal}) == uint8('-')))
                        values{iVal} = int64(str2double(values{iVal}));
                    end

                    % Floats may have decimals or exponents
                    if all(((uint8(values{iVal}) >= uint8('0')) & (uint8(values{iVal}) <= uint8('9'))) | ((uint8(values{iVal}) == uint8('-')) | (uint8(values{iVal}) == uint8('.')) | (uint8(values{iVal}) == uint8('e'))))
                        % UIDs are often numbers with multiple decimals and not valid numbers
                        if (sum(uint8(values{iVal}) == uint8('.')) < 2)
                            values{iVal} = str2double(values{iVal});
                        end
                    end
        
                    if (numel(values) == 1)
                        values = values{:};
                    elseif all(cellfun(@(x) isnumeric(x), values))
                        if numel(unique(cellfun(@(x) class(x), values, 'UniformOutput', false))) > 1
                            values = cellfun(@(x) double(x), values);
                        else
                            values = cell2mat(values);
                        end
                    end
        
                    metaStruct.(fields{iField}) = values;
                end
            end
        end

        % Append values to MetaAttributes struct
        function metaStruct = appendValue(metaStruct, name, value)
            if isfield(metaStruct, name)
                if iscell(metaStruct.(name))
                    metaStruct.(name){end+1} = value;
                elseif isnumeric(value)
                    if ~isnumeric(metaStruct.(name))
                        warning('value is numeric but existing values are not -- converting to string')
                        metaStruct.(name) = {metaStruct.(name), value};
                    else
                        metaStruct.(name)(end+1) = value;
                    end
                else
                    metaStruct.(name) = {metaStruct.(name), value};
                end
            else
                metaStruct.(name) = value;
            end
        end

    end % methods (Static)
end
