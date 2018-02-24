function initializeDataMySQL(dbName, userName, password, dataPath, interpolationWeightsFile)
% Function that prepares .mff data for further processing through Octave
% initializeDataMySQL(dbName, userName, password, dataPath, interpolationWeightsFile)
%     dbName: MySQL database name
%     userName: MySQL username
%     password: MySQL password
%     dataPath: parent directory of all of the .mff files
%     interpolationWeightsFile: .mat file containing the BESA interpolation weights

% Start MySQL connection
db = dbName;
user = userName;
pw = password;
driver = 'com.mysql.jdbc.Driver';

% useSSL=false doesn't work due to some weird implementation in database()
% that appends the database name to the end of the dbURL
% Ignore the warning for now
dbURL = ['jdbc:mysql://localhost:3306/' db %{'?useSSL=false'%}
        ];

% Requires path to the JDBC jar file (jdbcPath) 
% Change as required
jdbcPath = '/home/eeglewave/Documents/MATLAB/mysql-connector-java-5.1.40/mysql-connector-java-5.1.40-bin.jar';
javaaddpath(jdbcPath)

% Connect to the database
conn = database(db, user, pw, driver, dbURL);

% Query to select subject ID, division and name from SCAT3 and Child SCAT3 records
query = horzcat('(SELECT table_id.subj_id, table_id.division, age ', ...
                'FROM table_id, scat3 ', ...
                'WHERE table_id.subj_id = scat3.subj_id ', ...
                'GROUP BY subj_id) ', ...
                'UNION ALL ', ...
                '(SELECT table_id.subj_id, table_id.division, age ', ...
                'FROM table_id, child_scat3 ', ...
                'WHERE table_id.subj_id = child_scat3.subj_id ', ...
                'GROUP BY subj_id) ', ...
                'ORDER BY subj_id ASC;');
            
curs = exec(conn, query);
curs = fetch(curs);
subjectData = curs.Data;

fprintf('\n--------------- Retrieved subject data ---------------\n');
subjectData = sortrows(subjectData, 1)
IDData = subjectData(:,1);
divisionData = subjectData(:,2);
ageData = subjectData(:,3);

numPSDVals = 0;

D = dir([dataPath, '/*.mff']);
C = struct2cell(D);

D_raw = dir([dataPath, '/*.RAW']);
C_raw = struct2cell(D_raw);
C = [C C_raw];

addpath(genpath('/home/eeglewave/Documents/MATLAB/eeglab13_6_5b/'));
mff_setup


PSD_limits = [0 0];

if (~exist(strcat(dataPath, '/MAT'), 'dir'))
    mkdir(strcat(dataPath, '/MAT'));
end

processedFiles = 0;

% Load Interpolation Weights Matrix
if (nargin < 5)
    interpolationWeightsFile = '/home/eeglewave/Documents/Report Generation/Data/Interpolation/65Ch210-10Avg.mat';
else
    if (~exist(interpolationWeightsFile, 'file'))
        interpolationWeightsFile = '/home/eeglewave/Documents/Report Generation/Data/Interpolation/65Ch210-10Avg.mat'; 
    end
end

interpolationWeightsMAT = matfile(interpolationWeightsFile);
vars = whos(interpolationWeightsMAT);
W = interpolationWeightsMAT.(vars(1).name);

% Determine interpolation weights file directory
interpDirectory = fileparts(interpolationWeightsFile);
if isempty(interpDirectory)
    interpDirectory = pwd;
end

% Update the interpolation weights file information in the global data table
query = horzcat('UPDATE global_data SET interp_weights_folder=''', interpDirectory , ''' WHERE entry_id=1;');
curs = exec(conn, query);


subjChooseIdx = [];
% Prompt the user to enter subjects
prompt = 'Enter the subject IDs to be processed (separated by commas). Use colons (:) for ranges. Leave blank to process all subjects:\n';
choice = input(prompt,'s');
if (~isempty(choice))
    choice = strrep(choice, ' ', '');   % Remove all whitespace
    choice = strsplit(choice, ',');		% Split subjects
	choice = unique(choice);			% Remove duplicates
    numRanges = length(choice);         % Number of separate ranges (includes single subjects)
	rangeCount = 0;                     % Number of actual ranges (excludes single subjects) 
	totalSubjects = 0;                  % Total number of subjects (includes single subjects and multi-sized ranges)
	ranges = {};                        % Stores the ranges
	subjects = {};                      % Stores the single subjects
	
    % Extrapolate subject IDs based on the input ranges
	for n = 1:numRanges
		rangeChoice = strsplit(choice{n}, ':');     % Split each range into a start/stop bound
		
        % Ignore ranges of size 1 (single subjects)
		if (length(rangeChoice) > 1)
			rangePrefix = rangeChoice{1}(1:6);
			start = str2num(rangeChoice{1}(end-3:end));
			stop = str2num(rangeChoice{2}(end-3:end));
			
			% Swap values if start is bigger
			if (start > stop)
				dummy = start;
				start = stop;
				stop = dummy;
			end
			
			% Populate the range
			rangeSize = stop - start + 1;
			range = cell(rangeSize, 1);		
			for i = 1:rangeSize
				subjNum = start + i - 1;
                % Format the ID string for compliance with the current ID format string
                % Note: this assumes the form (TID)01(S)NNNN where:
                % - TID is a 3-character string for team identification (e.g. RFC, SFH, etc)
                % - S is a single-digit string for scan type (either B for baseline or C for concussed follow-ups)
                % - NNNN is a 4-digit numeric string
                % If the ID format string ever changes in the future, this will need to be updated
				if (length(num2str(subjNum)) == 1)
					rangeNumString = strcat('000', num2str(subjNum));
				elseif (length(num2str(subjNum)) == 2)
					rangeNumString = strcat('00', num2str(subjNum));
				elseif (length(num2str(subjNum)) == 3)
					rangeNumString = strcat('0', num2str(subjNum));
				else
					rangeNumString = num2str(subjNum);
                end
				
                % Populate ranges
				range{i} = strcat(rangePrefix, rangeNumString);
			end
			
			totalSubjects = totalSubjects + rangeSize;
			rangeCount = rangeCount + 1;
			ranges{rangeCount} = range;
        else
            % Populate single subjects
			subjects(n) = choice(n);
			totalSubjects = totalSubjects + 1;
		end
    end
	
    % Populate the chosen subjects with the single specified subjects
	for n = 1:length(subjects)
		choiceSubjects(n) = subjects(n);
    end
	
    % Populate the chosen subjects with the subjects extrapolated from the ranges
	startRangeCount = length(subjects);
	runningRangeCount = 0;
	for n = 1:length(ranges)
		currentRange = ranges{n};
		for i = 1:length(currentRange)
			runningRangeCount = runningRangeCount + 1;
			choiceSubjects(startRangeCount + runningRangeCount) = currentRange(i);
		end
    end
	
    % Remove duplicates
	choiceSubjects = unique(choiceSubjects);
	
    % Find the indices of the chosen subjects
    % Also ignores non-existent subject IDs
	subjChooseIdx = findCellIdx(IDData, choiceSubjects);
	subjChooseIdx = subjChooseIdx(subjChooseIdx ~= 0);
    numSubjects = length(subjChooseIdx);

    % Display a message if none of the subject IDs exist
	if isempty(subjChooseIdx)
		fprintf('\t');
		fprintf('No subjects found with those IDs.\n\n');
	end
else
    numSubjects = length(IDData);       % Selects all the subjects
	subjChooseIdx = 1:numSubjects;      % Find the indices of the subjects
end


%{
choice = input(prompt,'s');
if (~isempty(choice))
    choice = strrep(choice, ' ', '');   % Remove all whitespace
    choices = strsplit(choice, ',');    % Split subjects
    choices = unique(choices);
    numSubjects = length(choices);
else
    choices = IDData;
    numSubjects = numDataRows;
end
%}

for i = 1:numSubjects
    n = subjChooseIdx(i);
    fprintf('\n');
    fprintf('\tWorking on subject %s...\n', char(IDData(n)));
    findIdx = find(strncmpi(IDData(n), C(1,:), 10),1);
    if (findIdx)
        processedFiles = processedFiles + 1;
        filepath = strcat(dataPath, '/', C{1,findIdx});
        [path,name, ext] = fileparts(filepath);
        if(strcmp(ext,'.mff'))
            hdr = read_mff_header(filepath);
            str = strsplit(C{1,findIdx}, '_');
            subjID = str{1};
            
            %% Read the data
            fprintf('\t\tReading data... ');
            chan = []; % all channels
            numOfsamples_from = 1;
            numOfsamples_to = hdr.nSamples;
            %here data is 65 x NumOfTime
            data = read_mff_data(filepath,'sample', numOfsamples_from, numOfsamples_to, chan, hdr );
            %originalData = data; 
        elseif (strcmp(ext,'.RAW'))
            str = strsplit(C{1,findIdx}, '_');
            subjID = str{1};
            header =  pop_readegi(filepath);
            hdr.Fs = header.srate;
            %here data is 64 x NumOfTime
            data = double(header.data);
            %turn into 65 x NumOfTime to be consistent
            data = [data; zeros(size(header.times))];
        else
            disp('WARNING!! File Extension not recognized!!!');
        end

        newSubFolder = strcat(dataPath, '/MAT/', subjID);

        if ~exist(newSubFolder, 'dir')
            mkdir(newSubFolder);
        end
        
        % Insert subject folder into the database
        query = horzcat('REPLACE INTO eeg_data (subj_id, subj_folder) VALUES (''', subjID , ''', ''', newSubFolder, ''');');
        curs = exec(conn, query);

        savefileMATRaw = strcat(newSubFolder, '/matlab_raw.mat');
        savefileMATFiltered = strcat(newSubFolder, '/matlab_filtered.mat');
        savefileMATArtifactsRemoved = strcat(newSubFolder, '/matlab_artifacts_removed.mat');

        % Save raw data to .mat file
        save(savefileMATRaw, 'data');
        fprintf('Done.\n');

        %% Determine bad channels
        fprintf('\t\tDetermining bad channels... ');
        savefileBadChan = strcat(newSubFolder, '/bad_channels.mat');
        [badChannels, ~] = detectBadChannels(data);
        save(savefileBadChan, 'badChannels');
        fprintf('Done.\n');

        %% Filter the data
        % Determine sampling rate
        fs_ref = 250;       % Reference sampling rate
        fs = hdr.Fs;

        fprintf('\t\tFiltering data... ');
        % Resample data at 250 Hz
        % Make sure to leave it as a matrix of column vectors
        data = resample(data', fs_ref, fs);    % fs_ref/fs * fs = fs_ref = 250 Hz is the new sampling rate;

        fs = fs_ref;

        % Cutoff and notch frequencies (Hz)
        lowCutoff = 4;      % Low cutoff for high-pass
        highCutoff = 40;    % High cutoff for low-pass
        notchF = 60;        % Notch freq
        band = 2;           % Bandwidth for notch

        % Apply filters
        data = filterbandpass(data, lowCutoff, highCutoff, fs);
        data = filternotch(data, notchF, band, fs);
        fprintf('Done.\n');

        % Transpose the data set
        data = data';

        % Save filtered data
        save(savefileMATFiltered, 'data');

        %% Remove artifacts

        fprintf('\t\tRemoving artifacts...\n');
        numWindows = 500;
        stdFactor = 6;
        timeThreshold = 5*60;
        [data, classification] = removeArtifactsRecursive(data, fs, numWindows, stdFactor, timeThreshold);
        if (strcmp(classification, 'noisy'))
            fprintf(2,'\t\tWarning: the raw EEG data appeared to be very noisy, and much of it was removed. This may give unreliable results.\n');
        end
        savefileClass = strcat(newSubFolder, '/', classification, '.txt');
        fclose(fopen(savefileClass, 'w'));
        fprintf('\t\tDone.\n');

        % Save processed data
        save(savefileMATArtifactsRemoved, 'data');

        %% Interpolate using the weights matrix
        fprintf('\t\tInterpolating data... ');
        data = data'*W;     % Apply interpolation weights
        data = data';       % Transpose
        fprintf('Done.\n');

        %% Truncate data
        truncatePercent = 5;
        truncateSize = ceil(max(size(data))*truncatePercent/100);
        data = data(:, truncateSize:end-truncateSize);
        %truncateStart = 10000;
        %truncateEnd = 90000;
        %data = data(:, truncateStart:truncateEnd);

        %% Normalize data
        data = data';   % Transpose
        data = data - repmat(mean(data),size(data,1),1);
        data = data./repmat(std(data),size(data,1),1);

        savefileMAT_interp = strcat(newSubFolder, '/matlab.mat');
        %savefileMAT_PSD = strcat(newSubFolder, '/PSD_data.mat');
        savefileMAT_PSD_Single = strcat(newSubFolder, '/PSD_data_single_scalp_plot.mat');
        savefileTXT = strcat(newSubFolder, '/', num2str(ageData{n}), '.txt');

        %% Save the fully processed data
        fprintf('\t\tCreating matlab.mat... ');
        save(savefileMAT_interp, 'data');
        data = data';   % Transpose back
        fprintf('Done.\n');

        %% Save a text file of the subject's age
        fprintf('\t\tCreating %i.txt... ', ageData{n});
        fclose(fopen(savefileTXT, 'w'));
        fprintf('Done.\n');

        %% Calculate PSDs
        fprintf('\t\tCreating PSD_data.mat... ');
        PSD_data = getPSD_SingleScalpPlot(data);
        %numPSDVals = size(PSD_data, 1);

        %{
        if (processedFiles == 1)
            PSD_limits = [min(PSD_data) max(PSD_data)];
        end

        if (min(PSD_data) < PSD_limits(1))
            PSD_limits(1) = min(PSD_data);
        end

        if (max(PSD_data) > PSD_limits(2))
            PSD_limits(2) = max(PSD_data);
        end
        %}

        %% Update the scalp limits data in the database
        query = horzcat('REPLACE INTO scalp_lim_data (subj_id, scalp_lim_min, scalp_lim_max) VALUES (''', subjID , ''', ''', num2str(min(PSD_data)) , ''', ''', num2str(max(PSD_data)) , ''');');
        curs = exec(conn, query);

        %% Save the PSD data
        save(savefileMAT_PSD_Single, 'PSD_data');
        fprintf('Done.\n');

        fprintf('\tSuccessfully created files for subject %s.\n', IDData{n});
    else
        fprintf('\tError: No .mff files found for subject %s.\n', IDData{n});
    end
end

% Save scalp plot limits data
fprintf('\n');
fprintf('\tSaving scalp plot limits data... ');

% Get the smallest minimum PSD value
query = 'SELECT MIN(scalp_lim_min) FROM scalp_lim_data;';
curs = exec(conn, query);
curs = fetch(curs);
scalpMin = curs.Data;

% Get the largest minimum PSD value
query = 'SELECT MAX(scalp_lim_max) FROM scalp_lim_data;';
curs = exec(conn, query);
curs = fetch(curs);
scalpMax = curs.Data;

% Store the new PSD limits for the scalp plots into the database
PSD_limits = [scalpMin, scalpMax];

scalpPlotDatapath = strcat(dataPath, '/MAT/ScalpPlotData');
if ~exist(scalpPlotDatapath, 'dir')
    mkdir(scalpPlotDatapath)
end
save(strcat(scalpPlotDatapath, '/scalp_limits.mat'), 'PSD_limits');

% Update the scalp limits file information in the global data directory
query = horzcat('UPDATE global_data SET scalp_lim_folder=''', scalpPlotDatapath , ''' WHERE entry_id=1;');
curs = exec(conn, query);

fprintf('Done.\n');

%{
fprintf('\tCalculating average PSD data... ');
getPSDAverage(IDData, divisionData, dataPath, numPSDVals);
fprintf('Done\n');
%}

% Close MySQL connection
close(curs)
close(conn)

fprintf('\n');
fprintf('\tFinished processing files.\n');
fprintf('\n');

end