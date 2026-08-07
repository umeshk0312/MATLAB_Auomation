function varargout = CreateMILTestCaseSpreadsheet(varargin)
% CreateMILTestCaseSpreadsheet - Generate Excel spreadsheet for MIL test cases
%
% DESCRIPTION:
%   Creates a structured Excel template for Model-in-the-Loop (MIL) testing.
%   Extracts signal information from Simulink models and generates test case
%   spreadsheets with enumeration data.
%
% USAGE:
%   CreateMILTestCaseSpreadsheet()                              % Interactive mode
%   CreateMILTestCaseSpreadsheet('ModelPath', 'model.slx')      % Specify model
%   CreateMILTestCaseSpreadsheet('ProjectType', 'steering')     % Project type
%   CreateMILTestCaseSpreadsheet('EnumFolder', 'path/to/enums') % Custom enum folder
%
% PARAMETERS:
%   'ModelPath'   - Full path to Simulink model file (.slx)
%   'ProjectType' - Project type: 'generic', 'steering', 'brake', etc.
%   'ConfigFile'  - Path to custom configuration file (.mat)
%   'EnumFolder'  - Path to enumeration folder (overrides auto-selection)
%
% OUTPUT:
%   Excel file: '[ModelName]_MIL_TestCases.xlsx' with three sheets:
%   - Traceability matrix: Coverage tracking template
%   - TestCase_1: Main test case template with signal structure
%   - Enumerations: Enumeration definitions for signal types
%
% COPYRIGHT:
%   Unpublished Work Copyright (c) 2026 Deere & Company.
%   All Worldwide Rights Reserved.
%
% VERSION: 2.0 - Optimized and Enhanced
% LAST MODIFIED: February 26, 2026

    %% Input Argument Parsing
    p = inputParser;
    addParameter(p, 'ModelPath', '', @ischar);
    addParameter(p, 'ProjectType', 'generic', @ischar);
    addParameter(p, 'ConfigFile', '', @ischar);
    addParameter(p, 'EnumFolder', '', @ischar);
    addParameter(p, 'ExcelPath', '', @ischar);
    addParameter(p, 'OpenExcel', true, @(value) islogical(value) || isnumeric(value));
    parse(p, varargin{:});
    if nargout > 0
        varargout{1} = [];
    end
    
    modelPath = p.Results.ModelPath;
    projectType = p.Results.ProjectType;
    configFile = p.Results.ConfigFile;
    enumFolder = p.Results.EnumFolder;
    excelPath = p.Results.ExcelPath;
    openExcel = logical(p.Results.OpenExcel);

    try
        %% Step 1: Handle Model File Selection
        if isempty(modelPath)
            fprintf('\n=== Model Selection Required ===\n');
            fprintf('Please select a Simulink model file (.slx) to generate MIL test cases.\n');
            fprintf('The model should contain the control algorithm you want to test.\n');
            fprintf('File selection dialog will open in 2 seconds...\n\n');
            pause(2);
            [filename, pathname] = uigetfile('*.slx', 'Select Simulink Model File');
            if isequal(filename, 0)
                fprintf('Operation cancelled by user.\n');
                return;
            end
            fullModelPath = fullfile(pathname, filename);
        else
            fullModelPath = modelPath;
            [pathname, filename, ~] = fileparts(fullModelPath);
            filename = [filename '.slx'];
        end
        
        %% Step 2: Initialize Model Processing
        [~, modelName, ~] = fileparts(filename);
        if isempty(excelPath)
            outputFileName = sprintf('%s_MIL_TestCases.xlsx', modelName);
            outputFolder = pathname;
            fullOutputPath = fullfile(outputFolder, outputFileName);
        else
            [outputFolder, outputBaseName, outputExtension] = fileparts(excelPath);
            if isempty(outputFolder)
                outputFolder = pathname;
            end
            if isempty(outputExtension)
                outputExtension = '.xlsx';
            end
            outputFileName = [outputBaseName outputExtension];
            fullOutputPath = fullfile(outputFolder, outputFileName);
            if ~exist(outputFolder, 'dir')
                mkdir(outputFolder);
            end
        end
        
        fprintf('\n=== MIL Test Case Generator ===\n');
        fprintf('Model: %s\n', modelName);
        fprintf('Output: %s\n', outputFileName);
        fprintf('Location: %s\n', outputFolder);
        
        % Check if output Excel file is currently open before proceeding
        if exist(fullOutputPath, 'file')
            fprintf('\n=== Checking Excel File Status ===\n');
            fprintf('Checking if output file is currently open...\n');
            try
                % Try to open the file for writing to test if it's locked
                fid = fopen(fullOutputPath, 'a');
                if fid == -1
                    error('Cannot access file');
                end
                fclose(fid);
                fprintf('Output file is available for writing.\n');
            catch
                fprintf('\n=== ERROR: Excel File is Open ===\n');
                fprintf('The output file "%s" appears to be open in Excel.\n', outputFileName);
                fprintf('Please close the Excel file before running this script.\n');
                fprintf('Cannot proceed while the file is open.\n\n');
                error('Excel file "%s" is currently open. Please close it and re-run the script.', outputFileName);
            end
        end
        
        % Validate model file exists
        if ~exist(fullModelPath, 'file')
            error('Model file not found: %s', fullModelPath);
        end
        
        %% Step 3: Load Model and Configuration
        originalDir = pwd;
        cd(pathname);
        
        fprintf('\nLoading model: %s\n', modelName);
        load_system(modelName);
        
        config = loadProjectConfiguration(configFile, projectType);
        
        %% Step 4: Extract Signal Information
        fprintf('\nExtracting signal information...\n');
        [inputSignals, outputSignals] = extractModelSignals(modelName, config);
        
        %% Step 5: Create Test Case Template
        fprintf('\nCreating test case template...\n');
        testCaseData = createTestCaseTemplate(inputSignals, outputSignals, config);
        
        %% Step 6: Handle Enumeration Data
        enumerationFolder = selectEnumerationFolder(enumFolder);
        enumerationData = createEnumerationData(enumerationFolder, config);
        
        %% Step 7: Generate Excel File
        fprintf('\nGenerating Excel file...\n');
        generateExcelFile(fullOutputPath, testCaseData, enumerationData, inputSignals, outputSignals);
        
        %% Step 8: Success and Cleanup
        fprintf('\n=== SUCCESS ===\n');
        fprintf('Created: %s\n', outputFileName);
        fprintf('Location: %s\n', fullOutputPath);
        
        % Open Excel file automatically
        if openExcel
            openExcelFile(outputFolder, outputFileName);
        end

        outputInfo = struct();
        outputInfo.ModelPath = fullModelPath;
        outputInfo.ExcelPath = fullOutputPath;
        outputInfo.ModelName = modelName;
        outputInfo.OutputFolder = outputFolder;
        outputInfo.OutputFileName = outputFileName;
        if nargout > 0
            varargout{1} = outputInfo;
        end
        
        % Close model and return to original directory
        close_system(modelName, 0);
        cd(originalDir);
        
    catch ME
        %% Error Handling
        fprintf('\n=== ERROR ===\n');
        fprintf('Failed to create MIL test spreadsheet: %s\n', ME.message);
        
        % Cleanup: Close model if loaded
        try
            if exist('modelName', 'var') && bdIsLoaded(modelName)
                close_system(modelName, 0);
            end
        catch
            % Ignore cleanup errors
        end
        
        % Cleanup: Return to original directory
        try
            if exist('originalDir', 'var')
                cd(originalDir);
            end
        catch
            % Ignore cleanup errors
        end
        
        % Re-throw error for debugging
        rethrow(ME);
    end
end

%% =================================================================
%%                    CONFIGURATION FUNCTIONS
%% =================================================================

function config = loadProjectConfiguration(configFile, projectType)
% Load and apply project-specific configuration settings
%
% INPUT:
%   configFile  - Path to custom configuration file (optional)
%   projectType - Project type string ('generic', 'steering', etc.)
%
% OUTPUT:
%   config - Configuration structure with project settings
    
    config = struct();
    
    %% Load Custom Configuration File
    if ~isempty(configFile) && exist(configFile, 'file')
        try
            loadedConfig = load(configFile);
            if isfield(loadedConfig, 'config')
                config = loadedConfig.config;
            else
                config = loadedConfig;
            end
            fprintf('Loaded custom configuration: %s\n', configFile);
        catch ME
            warning('Failed to load configuration file: %s. Using defaults.', ME.message);
        end
    end
    
    %% Apply Project-Specific Settings
    % All project types now use generic configuration
    config = applyGenericConfiguration(config);
    
    fprintf('Applied configuration for: %s\n', projectType);
end

function config = applyGenericConfiguration(config)
% Apply generic configuration patterns
    if ~isfield(config, 'enumerationPatterns')
        config.enumerationPatterns = struct();
    end
    
    % Generic enumeration patterns that work for most projects
    % (Patterns removed as they are not required for this project)
end

function referenceStructure = analyzeExistingFile(filename)
% Analyze existing Excel file to understand expected structure
    referenceStructure = [];
    try
        % Get sheet information
        [~, sheetNames] = xlsfinfo(filename);
        if ~isempty(sheetNames)
            referenceStructure.sheetNames = sheetNames;
            fprintf('Found %d sheets: %s\n', length(sheetNames), strjoin(sheetNames, ', '));
            
            % Analyze first sheet (template) structure
            try
                [~, ~, rawData] = xlsread(filename, sheetNames{1});
                if ~isempty(rawData)
                    [numRows, numCols] = size(rawData);
                    referenceStructure.numRows = numRows;
                    referenceStructure.numCols = numCols;
                    referenceStructure.headers = rawData(4, :); % Assuming headers are in row 4
                    referenceStructure.signalTypes = rawData(2, :); % Row 2 for signal types
                    referenceStructure.dataTypes = rawData(3, :); % Row 3 for data types
                    
                    fprintf('Reference structure: %d rows x %d cols\n', numRows, numCols);
                    fprintf('Sample headers: %s\n', strjoin(rawData(4, 1:min(5,numCols)), ', '));
                end
            catch
                fprintf('Could not analyze reference structure in detail\n');
            end
            
            % Check if Enumerations sheet exists
            if any(contains(sheetNames, 'Enumerations'))
                referenceStructure.hasEnumerations = true;
                fprintf('Found Enumerations sheet\n');
            end
        end
    catch
        fprintf('Could not analyze existing file structure\n');
    end
end

%% =================================================================
%%                    SIGNAL EXTRACTION FUNCTIONS
%% =================================================================

function [inputSignals, outputSignals] = extractModelSignals(modelName, config)
% Extract input and output signal information from Simulink model
%
% INPUT:
%   modelName - Name of loaded Simulink model
%   config    - Configuration structure with custom settings
%
% OUTPUT:
%   inputSignals  - Struct array with .name and .dataType fields
%   outputSignals - Struct array with .name and .dataType fields
    
    inputSignals = struct('name', {}, 'dataType', {});
    outputSignals = struct('name', {}, 'dataType', {});
    
    %% Process Input Signals
    if isfield(config, 'inputSignals') && ~isempty(config.inputSignals)
        % Use predefined signals from configuration
        inputSignals = convertToSignalStruct(config.inputSignals);
        fprintf('Using %d predefined input signals\n', length(inputSignals));
    else
        % Extract from model (top-level only)
        inputSignals = extractPortSignals(modelName, 'Inport');
        fprintf('Extracted %d input signals from model\n', length(inputSignals));
    end
    
    %% Process Output Signals
    if isfield(config, 'outputSignals') && ~isempty(config.outputSignals)
        % Use predefined signals from configuration
        outputSignals = convertToSignalStruct(config.outputSignals);
        fprintf('Using %d predefined output signals\n', length(outputSignals));
    else
        % Extract from model (top-level only)
        outputSignals = extractPortSignals(modelName, 'Outport');
        fprintf('Extracted %d output signals from model\n', length(outputSignals));
    end

    % Prefix all output signal names for spreadsheet export
    outputSignals = prefixOutputSignalNames(outputSignals, 'EXP_');
    
    %% Display Results
    if ~isempty(inputSignals)
        inputNames = {inputSignals.name};
        inputTypes = {inputSignals.dataType};
        fprintf('Input signals: %s\n', strjoin(inputNames, ', '));
        fprintf('Input types: %s\n', strjoin(inputTypes, ', '));
    end
    
    if ~isempty(outputSignals)
        outputNames = {outputSignals.name};
        outputTypes = {outputSignals.dataType};
        fprintf('Output signals: %s\n', strjoin(outputNames, ', '));
        fprintf('Output types: %s\n', strjoin(outputTypes, ', '));
    end
end

function signalStruct = convertToSignalStruct(signalCell)
% Convert cell array of signal names to struct array with default data types
    signalStruct = struct('name', {}, 'dataType', {});
    if iscell(signalCell)
        for i = 1:length(signalCell)
            signalStruct(i).name = signalCell{i};
            signalStruct(i).dataType = 'double'; % Default type
        end
    else
        signalStruct = signalCell; % Already in correct format
    end
end

function outputSignals = prefixOutputSignalNames(outputSignals, prefix)
% Prefix output signal names unless they already contain the prefix
    for i = 1:length(outputSignals)
        if ~startsWith(outputSignals(i).name, prefix)
            outputSignals(i).name = [prefix outputSignals(i).name];
        end
    end
end

function signals = extractPortSignals(modelName, blockType)
% Extract signals from specific port type (Inport or Outport)
    signals = struct('name', {}, 'dataType', {});
    
    try
        % Find ports at top level only
        ports = find_system(modelName, 'SearchDepth', 1, 'BlockType', blockType);
        
        for i = 1:length(ports)
            portName = get_param(ports{i}, 'Name');
            
            % Get data type safely
            try
                portDataType = get_param(ports{i}, 'OutDataTypeStr');
                if isempty(portDataType) || strcmp(portDataType, 'Inherit: auto')
                    portDataType = 'double';
                end
                % Remove 'Enum: ' prefix if present
                if startsWith(portDataType, 'Enum: ')
                    portDataType = portDataType(7:end);
                end
            catch
                portDataType = 'double';
            end
            
            signals(end+1).name = portName; %#ok<AGROW>
            signals(end).dataType = portDataType;
        end
        
    catch
        warning('Could not extract %s signals. Using empty list.', blockType);
    end
end

%% =================================================================
%%                    ENUMERATION HANDLING FUNCTIONS
%% =================================================================

function enumerationFolder = selectEnumerationFolder(enumFolder)
% Handle enumeration folder selection with user interaction
%
% INPUT:
%   enumFolder - Predefined folder path (optional)
%
% OUTPUT:
%   enumerationFolder - Selected folder path or empty string
    
    if isempty(enumFolder)
        fprintf('\n=== Enumeration Folder Selection ===\n');
        fprintf('Please select the folder containing enumeration definitions (.m files).\n');
        fprintf('This folder should contain files like EnAutnFb.m.\n');
        fprintf('If you cancel, the tool will continue without enumeration data.\n');
        fprintf('Folder selection dialog will open in 2 seconds...\n\n');
        pause(2);
        enumerationFolder = uigetdir('', 'Select Enumeration Folder');
        if enumerationFolder == 0
            fprintf('No enumeration folder selected. Continuing without enumerations.\n');
            enumerationFolder = '';
        else
            fprintf('Selected enumeration folder: %s\n', enumerationFolder);
        end
    else
        enumerationFolder = enumFolder;
        fprintf('Using provided enumeration folder: %s\n', enumerationFolder);
    end
end

function openExcelFile(pathname, fileName)
% Open Excel file automatically with error handling
    try
        fullExcelPath = fullfile(pathname, fileName);
        fprintf('\nOpening Excel file...\n');
        winopen(fullExcelPath);
        fprintf('Excel file opened successfully\n');
    catch openErr
        fprintf('Warning: Could not open Excel file: %s\n', openErr.message);
        fprintf('Manual path: %s\n', fullfile(pathname, fileName));
    end
end

%% =================================================================
%%                    EXCEL GENERATION FUNCTIONS
%% =================================================================

function generateExcelFile(fileName, testCaseData, enumerationData, inputSignals, outputSignals)
% Generate complete Excel file with all sheets
%
% INPUT:
%   fileName        - Output Excel filename
%   testCaseData   - Test case template structure
%   enumerationData - Enumeration definitions
%   inputSignals   - Input signal information
%   outputSignals  - Output signal information

    % Remove existing file (already checked for access at script start)
    if exist(fileName, 'file')
        delete(fileName);
    end
    
    %% Create Traceability Matrix Sheet
    createTraceabilitySheet(fileName);
    
    %% Create Test Case Sheet
    createTestCaseSheet(fileName, testCaseData);
    
    %% Create Enumerations Sheet
    createEnumerationsSheet(fileName, enumerationData);
    
    fprintf('Excel file created with 3 sheets: Traceability, TestCase_1, Enumerations\n');
    fprintf('Signal summary: %d inputs, %d outputs\n', length(inputSignals), length(outputSignals));
end

function testCaseData = createTestCaseTemplate(inputSignals, outputSignals, config)
% Create test case data structure with 4-row header and enumeration mapping
    
    % Define time vector (configurable)
    if isfield(config, 'timeVector') && ~isempty(config.timeVector)
        timeVector = config.timeVector;
    else
        numTimePoints = 101; % 0:0.1:10 gives 101 points
        timeVector = (0:0.1:(numTimePoints-1)*0.1)';
    end
    
    % Initialize arrays - Time column will be handled separately
    signalTypes = {}; % Row 2: Input/Output types
    dataTypes = {};   % Row 3: Data types  
    signalNames = {}; % Row 4: Signal names
    
    % Add Time column 
    signalTypes{1} = '';            % Empty for Time in row 2
    dataTypes{1} = '';              % Empty for Time in row 3
    signalNames{1} = 'Time';        % 'Time' in row 4
    
    % Add input signals with Input/Output designation and actual data types
    for i = 1:length(inputSignals)
        signalTypes{end+1} = 'Input';
        dataTypes{end+1} = inputSignals(i).dataType;
        signalNames{end+1} = inputSignals(i).name;
    end
    
    % Add output signals with Input/Output designation and actual data types
    for i = 1:length(outputSignals)
        signalTypes{end+1} = 'Output';
        dataTypes{end+1} = outputSignals(i).dataType;
        signalNames{end+1} = outputSignals(i).name;
    end
    
    % Create test case data structure
    testCaseData.signalTypes = signalTypes;
    testCaseData.dataTypes = dataTypes;
    testCaseData.signalNames = signalNames;
    testCaseData.timeVector = timeVector;
    testCaseData.numCols = length(signalNames);
    testCaseData.numRows = 4; % 4 header rows
end

function enumType = detectEnumerationType(signalName, config)
% Detect enumeration type based on signal name patterns (configurable)
    
    signalLower = lower(signalName);
    enumType = 'Numeric'; % Default
    
    % Check for custom enumeration mappings in configuration
    if isfield(config, 'enumerationPatterns') && ~isempty(config.enumerationPatterns)
        patterns = config.enumerationPatterns;
        patternNames = fieldnames(patterns);
        
        for i = 1:length(patternNames)
            enumName = patternNames{i};
            keywords = patterns.(enumName);
            if any(contains(signalLower, keywords))
                enumType = enumName;
                return;
            end
        end
    end
    
    % Generic pattern detection (fallback)
    if contains(signalLower, {'errorstatus', 'error_status', 'status', 'sts'})
        enumType = 'statlist';
    elseif contains(signalLower, {'logl', 'logical', 'bool', 'enable', 'disable'})
        enumType = 'Boolean';
    else
        enumType = 'Numeric';
    end
end

function enumerationFolder = findEnumerationFolder(modelPath)
% Find the Enumeration folder relative to the model path - support multiple project structures
    
    % Try various common locations for the Enumeration folder
    possiblePaths = {
        fullfile(modelPath, '..', 'Enumeration'),          % Sibling folder
        fullfile(modelPath, 'Enumeration'),                % Same folder
        fullfile(modelPath, '..', '..', 'Enumeration'),    % Parent's sibling
        fullfile(modelPath, '..', 'Enumerations'),         % Plural form
        fullfile(modelPath, '..', 'enums'),                % Common abbreviation
        fullfile(modelPath, '..', 'Enums'),                % Capitalized abbreviation
        fullfile(modelPath, '..', 'DataTypes'),            % Alternative naming
        fullfile(modelPath, '..', 'Types'),                % Simple naming
        fullfile(modelPath, '..', '..', 'Common', 'Enumeration'), % Common shared folder
        fullfile(modelPath, '..', '..', 'Shared', 'Enumeration')  % Shared folder
    };
    
    enumerationFolder = '';
    for i = 1:length(possiblePaths)
        if exist(possiblePaths{i}, 'dir')
            enumerationFolder = possiblePaths{i};
            fprintf('Found Enumeration folder: %s\n', enumerationFolder);
            break;
        end
    end
    
    if isempty(enumerationFolder)
        warning('Enumeration folder not found, using default enumerations');
    end
end

function enumStruct = parseEnumerationFile(filePath)
% Parse a single enumeration .m file to extract enum values
    
    enumStruct = struct();
    enumStruct.name = '';
    enumStruct.values = {};
    enumStruct.numbers = [];
    
    try
        % Read the file content
        fid = fopen(filePath, 'r');
        if fid == -1
            return;
        end
        
        fileContent = fread(fid, '*char')';
        fclose(fid);
        
        % Extract class name
        classMatch = regexp(fileContent, 'classdef\s*\(Enumeration\)\s*(\w+)', 'tokens');
        if ~isempty(classMatch)
            enumStruct.name = classMatch{1}{1};
        end
        
        % Extract enumeration values
        enumMatch = regexp(fileContent, '(\w+)\s*\((\d+)\)', 'tokens');
        if ~isempty(enumMatch)
            for i = 1:length(enumMatch)
                enumStruct.values{end+1} = enumMatch{i}{1};
                enumStruct.numbers(end+1) = str2double(enumMatch{i}{2});
            end
        end
        
        fprintf('Parsed enumeration %s with %d values\n', enumStruct.name, length(enumStruct.values));
        
    catch ME
        fprintf('Error parsing enumeration file %s: %s\n', filePath, ME.message);
    end
end

function enumerationData = createEnumerationData(enumerationFolder, config)
% Create enumeration definitions from parsed enumeration files
    
    enumerationData = {};
    addedEnumerations = {}; % Track added enumeration names to avoid duplicates
    
    % Add default enumerations based on configuration
    if isfield(config, 'includeDefaultEnums') && config.includeDefaultEnums
        [enumerationData, addedEnumerations] = addDefaultEnumerations(enumerationData, addedEnumerations, config);
    else
        % Always include basic statlist and Boolean
        [enumerationData, addedEnumerations] = addBasicEnumerations(enumerationData, addedEnumerations);
    end
    
    % Parse enumeration files only if enumeration folder exists
    if ~isempty(enumerationFolder) && exist(enumerationFolder, 'dir')
        % Get all .m files in the enumeration folder
        enumFiles = dir(fullfile(enumerationFolder, '*.m'));
        
        for i = 1:length(enumFiles)
            filePath = fullfile(enumerationFolder, enumFiles(i).name);
            enumStruct = parseEnumerationFile(filePath);
            
            % Only add if enumeration name is not already added and not empty
            if ~isempty(enumStruct.name) && ~isempty(enumStruct.values) && ...
               ~any(strcmp(addedEnumerations, enumStruct.name))
                
                % Add enumeration header
                enumerationData{end+1, 1} = enumStruct.name;
                enumerationData{end, 2} = '';
                addedEnumerations{end+1} = enumStruct.name;
                
                % Add enumeration values
                for j = 1:length(enumStruct.values)
                    enumerationData{end+1, 1} = enumStruct.values{j};
                    enumerationData{end, 2} = enumStruct.numbers(j);
                end
                
                % Add end marker
                enumerationData{end+1, 1} = 'End';
                enumerationData{end, 2} = '';
                enumerationData{end+1, 1} = '';
                enumerationData{end, 2} = '';
            end
        end
    end
    
    fprintf('Created enumeration data with %d total entries from %d unique enumerations\n', size(enumerationData, 1), length(addedEnumerations));
end

function [enumData, addedEnums] = addBasicEnumerations(enumData, addedEnums)
% Add basic enumerations that are commonly used across projects
    
    % Add statlist enumeration (complete generic version for all models)
    enumData{end+1, 1} = 'statlist';
    enumData{end, 2} = '';
    addedEnums{end+1} = 'statlist';
    
    % Complete statlist values - generic for all models
    enumData{end+1, 1} = 'DATA_GOODDATA';
    enumData{end, 2} = -1;
    enumData{end+1, 1} = 'DATA_ValidAboveNormal';
    enumData{end, 2} = 0;
    enumData{end+1, 1} = 'DATA_ValidBelowNormal';
    enumData{end, 2} = 1;
    enumData{end+1, 1} = 'DATA_ErraticOrInvalid';
    enumData{end, 2} = 2;
    enumData{end+1, 1} = 'DATA_VoltageAboveNormal';
    enumData{end, 2} = 3;
    enumData{end+1, 1} = 'DATA_VoltageBelowNormal';
    enumData{end, 2} = 4;
    enumData{end+1, 1} = 'DATA_CurrentBelowNormal';
    enumData{end, 2} = 5;
    enumData{end+1, 1} = 'DATA_CurrentAboveNormal';
    enumData{end, 2} = 6;
    enumData{end+1, 1} = 'DATA_MechanicalOutOfAdjustment';
    enumData{end, 2} = 7;
    enumData{end+1, 1} = 'DATA_ErraticFrequency';
    enumData{end, 2} = 8;
    enumData{end+1, 1} = 'DATA_AbnormalUpdateRate';
    enumData{end, 2} = 9;
    enumData{end+1, 1} = 'DATA_AbnormalRateOfChange';
    enumData{end, 2} = 10;
    enumData{end+1, 1} = 'DATA_FailureNotIdentified';
    enumData{end, 2} = 11;
    enumData{end+1, 1} = 'DATA_BadDeviceOrComponent';
    enumData{end, 2} = 12;
    enumData{end+1, 1} = 'DATA_OutOfCalibration';
    enumData{end, 2} = 13;
    enumData{end+1, 1} = 'DATA_SpecialInstructions';
    enumData{end, 2} = 14;
    enumData{end+1, 1} = 'DATA_ValidAboveNormalLeastSevere';
    enumData{end, 2} = 15;
    enumData{end+1, 1} = 'DATA_ValidAboveNormalModeratelySevere';
    enumData{end, 2} = 16;
    enumData{end+1, 1} = 'DATA_ValidBelowNormalLeastSevere';
    enumData{end, 2} = 17;
    enumData{end+1, 1} = 'DATA_ValidBelowNormalModeratelySevere';
    enumData{end, 2} = 18;
    enumData{end+1, 1} = 'DATA_ReceivedNetworkDataInError';
    enumData{end, 2} = 19;
    enumData{end+1, 1} = 'DATA_NOTAVAILABLE';
    enumData{end, 2} = 31;
    
    enumData{end+1, 1} = 'End';
    enumData{end, 2} = '';
    enumData{end+1, 1} = '';
    enumData{end, 2} = '';
    
    % Add Boolean enumeration
    enumData{end+1, 1} = 'Boolean';
    enumData{end, 2} = '';
    addedEnums{end+1} = 'Boolean';
    enumData{end+1, 1} = 'FALSE';
    enumData{end, 2} = 0;
    enumData{end+1, 1} = 'TRUE';
    enumData{end, 2} = 1;
    enumData{end+1, 1} = 'End';
    enumData{end, 2} = '';
    enumData{end+1, 1} = '';
    enumData{end, 2} = '';
end

function [enumData, addedEnums] = addDefaultEnumerations(enumData, addedEnums, config)
% Add full default enumerations including project-specific ones
    
    % First add basic enumerations
    [enumData, addedEnums] = addBasicEnumerations(enumData, addedEnums);
    
    % Add project-specific default enumerations if defined in config
    if isfield(config, 'defaultEnumerations')
        defaultEnums = config.defaultEnumerations;
        enumNames = fieldnames(defaultEnums);
        
        for i = 1:length(enumNames)
            enumName = enumNames{i};
            if ~any(strcmp(addedEnums, enumName))
                enumValues = defaultEnums.(enumName);
                
                % Add enumeration header
                enumData{end+1, 1} = enumName;
                enumData{end, 2} = '';
                addedEnums{end+1} = enumName;
                
                % Add enumeration values
                valueNames = fieldnames(enumValues);
                for j = 1:length(valueNames)
                    enumData{end+1, 1} = valueNames{j};
                    enumData{end, 2} = enumValues.(valueNames{j});
                end
                
                % Add end marker
                enumData{end+1, 1} = 'End';
                enumData{end, 2} = '';
                enumData{end+1, 1} = '';
                enumData{end, 2} = '';
            end
        end
    end
end

function createTraceabilitySheet(fileName)
% Create traceability matrix sheet with coverage template
    
    tracibilityData = cell(11, 4);
    tracibilityData{5, 4} = 'Test case coverage';
    tracibilityData{6, 4} = 'High level requirement coverage';
    tracibilityData{7, 4} = 'Functional requirement coverage';
   
    try
        xlswrite(fileName, tracibilityData, 'Traciability matrix');
    catch
        writecell(tracibilityData, fileName, 'Sheet', 'Traciability matrix');
    end
end

function createTestCaseSheet(fileName, testCaseData)
% Create main test case sheet with signal structure
    
    % Build 4-row header structure
    sheetData = cell(4, testCaseData.numCols);
    
    % Row 1: Empty (reserved for future use)
    % Row 2: Input/Output designation
    for col = 1:testCaseData.numCols
        sheetData{2, col} = testCaseData.signalTypes{col};
    end
    
    % Row 3: Data types
    for col = 1:testCaseData.numCols
        sheetData{3, col} = testCaseData.dataTypes{col};
    end
    
    % Row 4: Signal names
    for col = 1:testCaseData.numCols
        sheetData{4, col} = testCaseData.signalNames{col};
    end
    
    % Write to Excel
    try
        xlswrite(fileName, sheetData, 'TestCase_1');
    catch
        writecell(sheetData, fileName, 'Sheet', 'TestCase_1');
    end
end

function createEnumerationsSheet(fileName, enumerationData)
% Create enumerations sheet with type definitions
    
    try
        xlswrite(fileName, enumerationData, 'Enumerations');
        fprintf('Successfully wrote enumeration data to Excel\n');
    catch
        try
            writecell(enumerationData, fileName, 'Sheet', 'Enumerations');
            fprintf('Successfully wrote enumeration data using writecell\n');
        catch writeErr
            error('Failed to write enumerations sheet: %s', writeErr.message);
        end
    end
end

% Additional utility functions for generic operation

function saveConfiguration(config, filename)
% Save current configuration to a file for reuse
    try
        save(filename, 'config');
        fprintf('Configuration saved to: %s\n', filename);
    catch ME
        warning('Failed to save configuration: %s', ME.message);
    end
end

function printUsageExamples()
% Print usage examples for different project types
    fprintf('\n=== CreateMILTestCaseSpreadsheet Usage Examples ===\n');
    fprintf('1. Interactive mode (prompts for model selection):\n');
    fprintf('   CreateMILTestCaseSpreadsheet()\n\n');
    fprintf('2. Specify model path:\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ModelPath'', ''C:\\path\\to\\model.slx'')\n\n');
    fprintf('3. Use specific project type:\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ProjectType'', ''steering'')\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ProjectType'', ''brake'')\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ProjectType'', ''engine'')\n\n');
    fprintf('4. Use custom configuration:\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ConfigFile'', ''my_config.mat'')\n\n');
    fprintf('5. Specify enumeration folder:\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''EnumFolder'', ''C:\\path\\to\\enums'')\n\n');
    fprintf('6. Combined usage:\n');
    fprintf('   CreateMILTestCaseSpreadsheet(''ModelPath'', ''model.slx'', ''ProjectType'', ''steering'', ''ConfigFile'', ''config.mat'')\n\n');
end
