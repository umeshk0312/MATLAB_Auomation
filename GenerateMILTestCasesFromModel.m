function summary = GenerateMILTestCasesFromModel(varargin)
% GenerateMILTestCasesFromModel - Create MIL test cases from a Simulink model.
%
% USAGE:
%   GenerateMILTestCasesFromModel('ModelPath', 'ABC.slx')
%   GenerateMILTestCasesFromModel('ModelPath', 'ABC.slx', 'ExcelPath', 'ABC_MIL_TestCases.xlsx')
%   GenerateMILTestCasesFromModel('ModelPath', 'ABC.slx', 'Mode', 'Pairwise')
%
% The generated workbook uses the existing MIL format:
%   Sheet 1: Traciability matrix
%   Test sheets: TestCase_1, TestCase_2, ...
%   Last sheet: Enumerations
%   Row 2: Input / Output
%   Row 3: data type or enum name
%   Row 4: signal names
%   Row 5+: time-series values

    parser = inputParser;
    addParameter(parser, 'ModelPath', '', @ischar);
    addParameter(parser, 'ExcelPath', '', @ischar);
    addParameter(parser, 'Mode', 'Auto', @ischar);
    addParameter(parser, 'SampleTime', 0.02, @(value) isnumeric(value) && isscalar(value) && value > 0);
    addParameter(parser, 'HoldSteps', 1, @(value) isnumeric(value) && isscalar(value) && value >= 1);
    addParameter(parser, 'UseSquareWaveEdges', true, @(value) islogical(value) || isnumeric(value));
    addParameter(parser, 'MaxTestCases', 64, @(value) isnumeric(value) && isscalar(value) && value >= 1);
    addParameter(parser, 'OpenExcel', false, @(value) islogical(value) || isnumeric(value));
    parse(parser, varargin{:});

    options = parser.Results;
    options.UseSquareWaveEdges = logical(options.UseSquareWaveEdges);
    options.OpenExcel = logical(options.OpenExcel);
    toolFolder = fileparts(mfilename('fullpath'));
    templateAlreadyCreated = false;

    fprintf('\n============================================================\n');
    fprintf(' MIL Test Case Generation Started\n');
    fprintf('============================================================\n');
    fprintf('Step 1/9: Reading user inputs and options...\n');

    if isempty(options.ModelPath)
        addpath(fileparts(toolFolder));
        templateInfo = CreateMILTestCaseSpreadsheet('ExcelPath', options.ExcelPath, 'OpenExcel', false);
        if isempty(templateInfo) || ~isfield(templateInfo, 'ModelPath') || ~isfield(templateInfo, 'ExcelPath')
            error('GenerateMILTestCasesFromModel:TemplateNotCreated', 'Template spreadsheet was not created.');
        end
        options.ModelPath = templateInfo.ModelPath;
        options.ExcelPath = templateInfo.ExcelPath;
        templateAlreadyCreated = true;
    end

    options.ModelPath = char(options.ModelPath);
    if ~exist(options.ModelPath, 'file')
        error('GenerateMILTestCasesFromModel:MissingModel', 'Model file not found: %s', options.ModelPath);
    end
    fprintf('  ModelPath: %s\n', options.ModelPath);
    fprintf('  Mode: %s\n', options.Mode);
    fprintf('  SampleTime: %.10g\n', options.SampleTime);
    fprintf('  UseSquareWaveEdges: %d\n', options.UseSquareWaveEdges);
    fprintf('  MaxTestCases: %d\n', options.MaxTestCases);

    [modelFolder, modelName, ~] = fileparts(options.ModelPath);
    generatedFolder = fullfile(toolFolder, 'Generated');
    fprintf('\nStep 2/9: Preparing output folder and workbook path...\n');
    if ~exist(generatedFolder, 'dir')
        fprintf('  Creating output folder: %s\n', generatedFolder);
        mkdir(generatedFolder);
    end
    if isempty(options.ExcelPath)
        options.ExcelPath = fullfile(generatedFolder, sprintf('%s_MIL_TestCases.xlsx', modelName));
    end
    fprintf('  WorkbookPath: %s\n', options.ExcelPath);

    fprintf('\n=== Generic MIL Test Case Generator ===\n');
    fprintf('Model: %s\n', options.ModelPath);
    fprintf('Workbook: %s\n', options.ExcelPath);
    fprintf('Mode: %s\n', options.Mode);

    originalFolder = pwd;
    cleanupObj = onCleanup(@() cd(originalFolder));
    cd(modelFolder);

    fprintf('\nStep 3/9: Loading Simulink model...\n');
    load_system(options.ModelPath);
    modelCleanup = onCleanup(@() closeModelIfLoaded(modelName));
    fprintf('  Loaded model: %s\n', modelName);

    fprintf('\nStep 4/9: Discovering top-level input and output ports...\n');
    ports = inspectModelPorts(modelName);
    validateSupportedPorts(ports);
    fprintf('  Input ports discovered: %d\n', numel(ports.inputs));
    fprintf('  Output ports discovered: %d\n', numel(ports.outputs));

    testRows = generateInputRows(ports.inputs, options);

    testRows = buildTimeSeriesRows(testRows, options);

    outputRows = simulateExpectedOutputs(modelName, ports, testRows, options);

    workbookData = buildWorkbookData(ports, testRows, outputRows);

    writeWorkbook(options.ExcelPath, workbookData, ports, options.ModelPath, toolFolder, templateAlreadyCreated);

    summary = struct();
    summary.ModelName = modelName;
    summary.ExcelPath = options.ExcelPath;
    summary.InputCount = numel(ports.inputs);
    summary.OutputCount = numel(ports.outputs);
    summary.DataRows = size(testRows.values, 1);
    summary.TestSheets = 1;

    fprintf('\n=== SUCCESS ===\n');
    fprintf('Created MIL workbook: %s\n', options.ExcelPath);
    fprintf('Inputs: %d, Outputs: %d, Data rows: %d\n', summary.InputCount, summary.OutputCount, summary.DataRows);
    fprintf('============================================================\n');
    fprintf(' MIL Test Case Generation Finished\n');
    fprintf('============================================================\n');

    if options.OpenExcel
        try
            winopen(options.ExcelPath);
        catch openError
            warning('GenerateMILTestCasesFromModel:OpenExcelFailed', 'Could not open workbook: %s', openError.message);
        end
    end
end

function closeModelIfLoaded(modelName)
    try
        if bdIsLoaded(modelName)
            close_system(modelName, 0);
        end
    catch
    end
end

function ports = inspectModelPorts(modelName)
    inputBlocks = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Inport');
    outputBlocks = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Outport');

    ports = struct();
    ports.inputs = inspectPortBlocks(inputBlocks, true);
    ports.outputs = inspectPortBlocks(outputBlocks, false);

    fprintf('\nDiscovered ports:\n');
    printPorts('Input', ports.inputs);
    printPorts('Output', ports.outputs);
end

function portInfo = inspectPortBlocks(blocks, isInput)
    portInfo = struct('name', {}, 'blockPath', {}, 'dataType', {}, 'baseType', {}, 'values', {}, 'isInput', {}, 'isEnum', {}, 'isBoolean', {}, 'isNumeric', {});
    for index = 1:numel(blocks)
        blockPath = blocks{index};
        dataType = getPortDataType(blockPath);
        [baseType, isEnum] = normalizeDataType(dataType);

        portInfo(index).name = strtrim(get_param(blockPath, 'Name'));
        portInfo(index).blockPath = blockPath;
        portInfo(index).dataType = dataType;
        portInfo(index).baseType = baseType;
        portInfo(index).values = defaultValuesForType(baseType, isEnum);
        portInfo(index).isInput = isInput;
        portInfo(index).isEnum = isEnum;
        portInfo(index).isBoolean = isBooleanType(baseType);
        portInfo(index).isNumeric = isNumericType(baseType);
    end
end

function dataType = getPortDataType(blockPath)
    try
        dataType = get_param(blockPath, 'OutDataTypeStr');
    catch
        dataType = 'double';
    end

    if isempty(dataType) || strcmp(dataType, 'Inherit: auto')
        dataType = 'double';
    end
end

function [baseType, isEnum] = normalizeDataType(dataType)
    baseType = strtrim(dataType);
    isEnum = false;
    if startsWith(baseType, 'Enum: ')
        baseType = strtrim(baseType(7:end));
        isEnum = true;
    end
end

function values = defaultValuesForType(baseType, isEnum)
    if isBooleanType(baseType)
        values = {false, true};
    elseif isEnum
        values = enumValues(baseType);
    elseif isNumericType(baseType)
        values = numericValues(baseType);
    else
        values = {0};
    end
end

function tf = isBooleanType(baseType)
    tf = any(strcmpi(baseType, {'boolean', 'bool', 'logical'}));
end

function tf = isNumericType(baseType)
    numericTypes = {'double', 'single', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'int64', 'uint64'};
    tf = any(strcmpi(baseType, numericTypes)) || startsWith(baseType, 'fixdt');
end

function values = enumValues(enumType)
    values = {};
    try
        metaClass = meta.class.fromName(enumType);
        if ~isempty(metaClass) && ~isempty(metaClass.EnumerationMemberList)
            members = metaClass.EnumerationMemberList;
            for index = 1:numel(members)
                values{end+1} = members(index).Name; %#ok<AGROW>
            end
        end
    catch
        values = {};
    end

    if isempty(values)
        warning('GenerateMILTestCasesFromModel:EnumValuesUnknown', 'Could not discover enum values for %s. Using 0.', enumType);
        values = {0};
    end
end

function values = numericValues(baseType)
    switch lower(baseType)
        case {'uint8', 'uint16', 'uint32', 'uint64'}
            values = {0, 1};
        case {'int8', 'int16', 'int32', 'int64'}
            values = {-1, 0, 1};
        otherwise
            values = {-1, 0, 1};
    end
end

function validateSupportedPorts(ports)
    if isempty(ports.inputs)
        error('GenerateMILTestCasesFromModel:NoInputs', 'The model has no top-level input ports.');
    end

    if isempty(ports.outputs)
        error('GenerateMILTestCasesFromModel:NoOutputs', 'The model has no top-level output ports.');
    end
end

function printPorts(kind, portInfo)
    for index = 1:numel(portInfo)
        fprintf('  %s: %s (%s)\n', kind, portInfo(index).name, portInfo(index).dataType);
    end
end

function testRows = generateInputRows(inputs, options)
    candidateValues = {inputs.values};
    combinationCount = 1;
    for index = 1:numel(candidateValues)
        combinationCount = combinationCount * numel(candidateValues{index});
    end

    mode = lower(options.Mode);
    if strcmp(mode, 'auto')
        if combinationCount <= options.MaxTestCases
            mode = 'exhaustive';
        else
            mode = 'pairwise';
        end
    end

    switch mode
        case {'exhaustive', 'truthtable'}
            rows = exhaustiveRows(candidateValues, options.MaxTestCases);
        case 'pairwise'
            rows = pairwiseRows(candidateValues, options.MaxTestCases);
        case 'smoke'
            rows = smokeRows(candidateValues);
        otherwise
            error('GenerateMILTestCasesFromModel:UnknownMode', 'Unsupported mode: %s', options.Mode);
    end

    testRows = struct();
    testRows.values = rows;
    testRows.inputNames = {inputs.name};
end

function rows = exhaustiveRows(candidateValues, maxRows)
    inputCount = numel(candidateValues);
    grids = cell(1, inputCount);
    indexVectors = cell(1, inputCount);
    for index = 1:inputCount
        indexVectors{index} = 1:numel(candidateValues{index});
    end

    [grids{:}] = ndgrid(indexVectors{:});
    rowCount = numel(grids{1});
    rowCount = min(rowCount, maxRows);
    rows = cell(rowCount, inputCount);

    for row = 1:rowCount
        for col = 1:inputCount
            valueIndex = grids{col}(row);
            rows{row, col} = candidateValues{col}{valueIndex};
        end
    end
end

function rows = pairwiseRows(candidateValues, maxRows)
    inputCount = numel(candidateValues);
    rowCount = min(max(cellfun(@numel, candidateValues)), maxRows);
    rows = cell(rowCount, inputCount);

    for row = 1:rowCount
        for col = 1:inputCount
            values = candidateValues{col};
            valueIndex = mod(row + col - 2, numel(values)) + 1;
            rows{row, col} = values{valueIndex};
        end
    end

    if rowCount < maxRows && inputCount > 1
        for left = 1:inputCount
            for right = left + 1:inputCount
                for leftIndex = 1:numel(candidateValues{left})
                    for rightIndex = 1:numel(candidateValues{right})
                        if size(rows, 1) >= maxRows
                            return;
                        end
                        newRow = rows(1, :);
                        newRow{left} = candidateValues{left}{leftIndex};
                        newRow{right} = candidateValues{right}{rightIndex};
                        rows(end + 1, :) = newRow; %#ok<AGROW>
                    end
                end
            end
        end
    end
end

function rows = smokeRows(candidateValues)
    rows = cell(1, numel(candidateValues));
    for col = 1:numel(candidateValues)
        rows{1, col} = candidateValues{col}{1};
    end
end

function timeRows = buildTimeSeriesRows(testRows, options)
    baseRows = testRows.values;
    dataRows = {};
    timeValues = [];
    currentTime = 0;

    for row = 1:size(baseRows, 1)
        if row == 1 || ~options.UseSquareWaveEdges
            currentTime = currentTime + options.SampleTime;
            dataRows(end + 1, :) = baseRows(row, :); %#ok<AGROW>
            timeValues(end + 1, 1) = currentTime; %#ok<AGROW>
        else
            previousRow = dataRows(end, :);
            dataRows(end + 1, :) = previousRow; %#ok<AGROW>
            timeValues(end + 1, 1) = currentTime; %#ok<AGROW>

            dataRows(end + 1, :) = baseRows(row, :); %#ok<AGROW>
            timeValues(end + 1, 1) = currentTime; %#ok<AGROW>
        end

        for holdIndex = 1:options.HoldSteps
            currentTime = currentTime + options.SampleTime;
            dataRows(end + 1, :) = baseRows(row, :); %#ok<AGROW>
            timeValues(end + 1, 1) = currentTime; %#ok<AGROW>
        end
    end

    timeRows = testRows;
    timeRows.values = dataRows;
    timeRows.time = timeValues;
    timeRows.simTime = makeStrictlyIncreasingTime(timeValues, options.SampleTime);
    timeRows.outputSampleTime = timeRows.simTime;
end

function simTime = makeStrictlyIncreasingTime(timeValues, sampleTime)
    simTime = (1:numel(timeValues))' * sampleTime;
end

function outputRows = simulateExpectedOutputs(modelName, ports, testRows, options)
    outputRows = cell(size(testRows.values, 1), numel(ports.outputs));

    try
        inputDataset = createInputDataset(ports.inputs, testRows);
        assignin('base', 'MIL_InputDataset', inputDataset);
        stopTime = num2str(max(testRows.outputSampleTime));
        set_param(modelName, 'LoadExternalInput', 'on');
        set_param(modelName, 'ExternalInput', 'MIL_InputDataset');
        set_param(modelName, 'StopTime', stopTime);
        set_param(modelName, 'SaveOutput', 'on');
        set_param(modelName, 'OutputSaveName', 'yout');
        set_param(modelName, 'SaveFormat', 'Dataset');
        simOut = sim(modelName, 'StopTime', stopTime);
        outputRows = extractSimulationOutputs(simOut, ports.outputs, testRows, options);
    catch simulationError
        warning('GenerateMILTestCasesFromModel:SimulationFailed', 'Simulation failed. Output columns will be initialized with default values. Reason: %s', simulationError.message);
        outputRows = defaultOutputRows(ports.outputs, size(testRows.values, 1));
    end
end

function inputDataset = createInputDataset(inputs, testRows)
    inputDataset = Simulink.SimulationData.Dataset;
    for index = 1:numel(inputs)
        signalValues = cellColumnToSimulationValues(testRows.values(:, index), inputs(index));
        signal = timeseries(signalValues, testRows.simTime);
        signal.Name = inputs(index).name;
        inputDataset = inputDataset.addElement(signal, inputs(index).name);
    end
end

function values = cellColumnToSimulationValues(columnValues, portInfo)
    if portInfo.isBoolean
        values = false(numel(columnValues), 1);
    else
        values = zeros(numel(columnValues), 1);
    end
    for index = 1:numel(columnValues)
        values(index, 1) = valueToSimulationValue(columnValues{index}, portInfo);
    end
end

function outputRows = extractSimulationOutputs(simOut, outputs, testRows, options)
    outputRows = defaultOutputRows(outputs, size(testRows.values, 1));
    try
        yout = simOut.get('yout');
    catch
        return;
    end

    if isa(yout, 'Simulink.SimulationData.Dataset')
        for index = 1:numel(outputs)
            element = findDatasetElement(yout, outputs(index).name, index);
            if isempty(element)
                continue;
            end
            outputRows(:, index) = sampleOutputElement(element, testRows.outputSampleTime, outputs(index), options);
        end
    elseif isnumeric(yout)
        for index = 1:min(numel(outputs), size(yout, 2))
            outputRows(:, index) = numericVectorToCells(yout(:, index), outputs(index));
        end
    end
end

function element = findDatasetElement(dataset, signalName, fallbackIndex)
    element = [];
    try
        names = dataset.getElementNames;
        matchIndex = find(strcmp(names, signalName), 1);
        if ~isempty(matchIndex)
            element = dataset.get(matchIndex);
        end
    catch
    end

    if isempty(element)
        try
            element = dataset.get(fallbackIndex);
        catch
        end
    end
end

function values = sampleOutputElement(element, timeVector, portInfo, options)
    values = cell(numel(timeVector), 1);
    try
        signalValues = element.Values;
        for index = 1:numel(timeVector)
            sample = getsampleusingtime(signalValues, timeVector(index), timeVector(index));
            if isempty(sample.Data)
                sample = getsampleusingtime(signalValues, max(0, timeVector(index) - options.SampleTime), timeVector(index));
            end
            data = sample.Data;
            if isempty(data)
                values{index} = defaultValueForOutput(portInfo);
            else
                values{index} = numericToWorkbookValue(data(end), portInfo);
            end
        end
    catch
        for index = 1:numel(timeVector)
            values{index} = defaultValueForOutput(portInfo);
        end
    end
end

function values = numericVectorToCells(vector, portInfo)
    values = cell(numel(vector), 1);
    for index = 1:numel(vector)
        values{index} = numericToWorkbookValue(vector(index), portInfo);
    end
end

function outputRows = defaultOutputRows(outputs, rowCount)
    outputRows = cell(rowCount, numel(outputs));
    for row = 1:rowCount
        for col = 1:numel(outputs)
            outputRows{row, col} = defaultValueForOutput(outputs(col));
        end
    end
end

function value = defaultValueForOutput(portInfo)
    if portInfo.isBoolean
        value = 'FALSE';
    else
        value = 0;
    end
end

function value = valueToSimulationValue(value, portInfo)
    if islogical(value)
        if ~portInfo.isBoolean
            value = double(value);
        end
    elseif isnumeric(value)
        if portInfo.isBoolean
            value = logical(value);
        else
            value = double(value);
        end
    elseif ischar(value)
        if portInfo.isBoolean
            value = strcmpi(value, 'TRUE');
        else
            numericValue = str2double(value);
            if isnan(numericValue)
                numericValue = 0;
            end
            value = numericValue;
        end
    else
        value = 0;
    end
end

function value = numericToWorkbookValue(value, portInfo)
    if portInfo.isBoolean
        if logical(value)
            value = 'TRUE';
        else
            value = 'FALSE';
        end
    else
        value = double(value);
    end
end

function workbookData = buildWorkbookData(ports, testRows, outputRows)
    inputCount = numel(ports.inputs);
    outputCount = numel(ports.outputs);
    columnCount = 1 + inputCount + outputCount;
    rowCount = 4 + size(testRows.values, 1);
    sheetData = cell(rowCount, columnCount);

    sheetData{1, 1} = 'Generated MIL Test Case';
    sheetData{2, 1} = '';
    sheetData{3, 1} = '';
    sheetData{4, 1} = 'Time';

    for index = 1:inputCount
        col = index + 1;
        sheetData{2, col} = 'Input';
        sheetData{3, col} = workbookTypeName(ports.inputs(index));
        sheetData{4, col} = ports.inputs(index).name;
    end

    for index = 1:outputCount
        col = 1 + inputCount + index;
        sheetData{2, col} = 'Output';
        sheetData{3, col} = workbookTypeName(ports.outputs(index));
        sheetData{4, col} = ['EXP_' ports.outputs(index).name];
    end

    for row = 1:size(testRows.values, 1)
        sheetRow = row + 4;
        sheetData{sheetRow, 1} = testRows.time(row);
        for col = 1:inputCount
            sheetData{sheetRow, col + 1} = workbookInputValue(testRows.values{row, col}, ports.inputs(col));
        end
        for col = 1:outputCount
            sheetData{sheetRow, 1 + inputCount + col} = outputRows{row, col};
        end
    end

    workbookData = sheetData;
end

function typeName = workbookTypeName(portInfo)
    if portInfo.isBoolean
        typeName = 'boolean';
    elseif portInfo.isEnum
        typeName = portInfo.baseType;
    elseif portInfo.isNumeric
        typeName = 'Numeric';
    else
        typeName = portInfo.baseType;
    end
end

function value = workbookInputValue(value, portInfo)
    if portInfo.isBoolean
        if logical(value)
            value = 'TRUE';
        else
            value = 'FALSE';
        end
    end
end

function writeWorkbook(excelPath, testCaseData, ports, modelPath, toolFolder, templateAlreadyCreated)
    if ~templateAlreadyCreated && ~exist(excelPath, 'file')
        createTemplateWorkbook(modelPath, excelPath, toolFolder);
    end

    if ~exist(excelPath, 'file')
        error('GenerateMILTestCasesFromModel:MissingTemplateWorkbook', ...
            'Expected template workbook was not found: %s', excelPath);
    end

    writeCellData(excelPath, testCaseData, 'TestCase_1');
    writeCellData(excelPath, createEnumerationsData(ports), 'Enumerations');
end

function createTemplateWorkbook(modelPath, excelPath, toolFolder)
    templateToolFolder = fileparts(toolFolder);
    noAdditionalEnumsFolder = fullfile(toolFolder, 'NoAdditionalEnums');
    addpath(templateToolFolder);
    CreateMILTestCaseSpreadsheet('ModelPath', modelPath, ...
        'ExcelPath', excelPath, ...
        'EnumFolder', noAdditionalEnumsFolder, ...
        'OpenExcel', false);
end

function checkWorkbookWritable(excelPath)
    fileId = fopen(excelPath, 'a');
    if fileId == -1
        error('GenerateMILTestCasesFromModel:WorkbookLocked', 'Workbook is open or not writable: %s', excelPath);
    end
    fclose(fileId);
end

function createTraceabilitySheet(excelPath)
    data = cell(11, 4);
    data{1, 1} = 'Generated MIL test cases';
    data{5, 4} = 'Test case coverage';
    data{6, 4} = 'High level requirement coverage';
    data{7, 4} = 'Functional requirement coverage';
    writeCellData(excelPath, data, 'Traciability matrix');
end

function enumData = createEnumerationsData(ports)
    enumData = basicEnumerations();
    allPorts = [ports.inputs ports.outputs];
    for index = 1:numel(allPorts)
        if allPorts(index).isEnum
            enumData = appendEnumValues(enumData, allPorts(index).baseType, allPorts(index).values);
        end
    end
end

function enumData = basicEnumerations()
    enumData = {
        'statlist', '';
        'DATA_GOODDATA', -1;
        'DATA_ValidAboveNormal', 0;
        'DATA_ValidBelowNormal', 1;
        'DATA_ErraticOrInvalid', 2;
        'DATA_VoltageAboveNormal', 3;
        'DATA_VoltageBelowNormal', 4;
        'DATA_CurrentBelowNormal', 5;
        'DATA_CurrentAboveNormal', 6;
        'DATA_MechanicalOutOfAdjustment', 7;
        'DATA_ErraticFrequency', 8;
        'DATA_AbnormalUpdateRate', 9;
        'DATA_AbnormalRateOfChange', 10;
        'DATA_FailureNotIdentified', 11;
        'DATA_BadDeviceOrComponent', 12;
        'DATA_OutOfCalibration', 13;
        'DATA_SpecialInstructions', 14;
        'DATA_ValidAboveNormalLeastSevere', 15;
        'DATA_ValidAboveNormalModeratelySevere', 16;
        'DATA_ValidBelowNormalLeastSevere', 17;
        'DATA_ValidBelowNormalModeratelySevere', 18;
        'DATA_ReceivedNetworkDataInError', 19;
        'DATA_NOTAVAILABLE', 31;
        'End', '';
        '', '';
        'Boolean', '';
        'FALSE', 0;
        'TRUE', 1;
        'End', '';
        '', '';
        'Numeric', '';
        'Value', 0;
        'End', ''
    };
end

function enumData = appendEnumValues(enumData, enumName, enumValues)
    enumData(end + 1, :) = {'', ''};
    enumData(end + 1, :) = {enumName, ''};
    for index = 1:numel(enumValues)
        enumData(end + 1, :) = {enumValues{index}, index - 1}; %#ok<AGROW>
    end
    enumData(end + 1, :) = {'End', ''};
end

function writeCellData(excelPath, data, sheetName)
    try
        writecell(data, excelPath, 'Sheet', sheetName);
    catch
        xlswrite(excelPath, data, sheetName);
    end
end