function roi = create_roi(x, y, rgb, thickness, style, visibility)
%     Create an MRD-formatted ROI
%         Input:
%             - x (1 x n or n x 1 array) : x coordinates in units of pixels, with (0,0) at the top left
%             - y (1 x n or n x 1 array) : y coordinates in units of pixels, matching the length of x
%             - rgb (1 x 3 array)        : Colour as a [red, green, blue] array with values normalized to 1 (default: [1 0 0], i.e. red)
%             - thickness (double)       : Line thickness (default: 1)
%             - style (int)              : Line style (0 = solid, 1 = dashed, default: 0)
%             - visibility (int)         : Line visibility (0 = false, 1 = true, default: 1)
%         Output:
%             - roi (string array)       : MRD-formatted ROI, intended to be stored as a MetaAttribute
%                                          with field name starting with "ROI_"

    if nargin < 3
        rgb = [1 0 0];
    end

    if nargin < 4
        thickness = 1;
    end

    if nargin < 5
        style = 0;
    end

    if nargin < 6
        visibility = 1;
    end

    roi = cell(0);

    roi = cat(2, roi, sprintfc('%g', rgb));
    roi = cat(2, roi, sprintf('%g', thickness));
    roi = cat(2, roi, sprintf('%g', style));
    roi = cat(2, roi, sprintf('%g', visibility));

    for i = 1:numel(x)
        roi = cat(2, roi, sprintfc('%g', [x(i) y(i)]));
    end
end
