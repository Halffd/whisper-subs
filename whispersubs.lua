-- This is the main variable you will want to modify	
-- Set things like the model location and language, just avoid setting any input or output options
local WHISPER_CMD = "whisper-cli -m /home/half-arch/models/ggml-base.bin --threads 4 --no-prints --language auto"

-- Additional variables
local CHUNK_SIZE = 5 * 1000        -- Keep the 5-second chunks
local WAV_CHUNK_SIZE = CHUNK_SIZE + 1000 -- Reduce padding
local START_AT_ZERO = true		 -- start creating subs from 00:00:00 rather than the current time position (local files only)
local SAVE_SRT = true			 -- save srt file when finished processing (local files only)
local SHOW_PROGRESS = true		 -- visual aid to see where it's still processing subtitles
local MAX_CACHE_SIZE = 50 * 1024 * 1024  -- Reduce to 50MB
local FORCE_SUB_VISIBILITY = true

-- These are just some temp files in order to process the subs
-- pid must be used in case multiple instances of the script are running at once
local pid = mp.get_property_native('pid')
local TMP_WAV_PATH = "/tmp/mpv_whisper_tmp_wav_"..pid..".wav"
local TMP_SUB_PATH = "/tmp/mpv_whisper_tmp_sub_"..pid -- without file ext "srt"
local TMP_CACHE_PATH = "/tmp/mpv_whisper_tmp_cache_"..pid..".mkv"

local running = false
local chunk_dur

-- Add these debug functions near the top
local function debug_log(msg)
	mp.msg.debug("WhisperSubs: " .. msg)
end

local function error_log(msg)
	mp.msg.error("WhisperSubs: " .. msg)
end

local function formatProgress(ms)
	local seconds = math.floor(ms / 1000)
	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)

	local seconds = seconds % 60
	local minutes = minutes % 60
	local hours = hours % 24

	return string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, ms % 1000)
end

local function cleanup()
	debug_log("Cleaning up temporary files")
	-- Use pcall to handle potential errors in cleanup
	pcall(function()
		os.execute('rm -f "'..TMP_WAV_PATH..'"')
		os.execute('rm -f "'..TMP_SUB_PATH..'."*')
		os.execute('rm -f "'..TMP_CACHE_PATH..'"*')
	end)
end

local function stop()
	running = false
	mp.unregister_event(stop)
	cleanup()
end

local function saveSubs(media_path)
	local sub_path = media_path:match("(.+)%..+$") -- remove file ext from media
	sub_path = sub_path..'.srt'..'"' -- add the file ext back with the "

	mp.commandv('show-text', 'Whisper: Subtitles finished processing, saving to'..sub_path, 5000)

	os.execute('cp '..TMP_SUB_PATH..'.srt '..sub_path, 'r')
end

local function ensureSubVisibility()
	if FORCE_SUB_VISIBILITY then
		mp.set_property("sub-visibility", "yes")
		mp.set_property("secondary-sub-visibility", "yes")
	end
end

-- Add these helper functions at the top after the existing debug functions
local function time_to_ms(time_str)
	local h, m, s, ms = time_str:match("(%d%d):(%d%d):(%d%d),(%d%d%d)")
	return (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)) * 1000 + tonumber(ms)
end

local function ms_to_time(ms)
	local h = math.floor(ms / 3600000)
	ms = ms % 3600000
	local m = math.floor(ms / 60000)
	ms = ms % 60000
	local s = math.floor(ms / 1000)
	ms = ms % 1000
	return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

-- Add this function to help with debugging
local function dump_timing_info(prefix, pos)
	local time_pos = mp.get_property_number("time-pos") or 0
	local cache_time = mp.get_property_number("demuxer-cache-time") or 0
	local cache_duration = mp.get_property_number("demuxer-cache-duration") or 0
	debug_log(string.format("%s: current_pos=%d, time_pos=%.3f, cache_time=%.3f, cache_duration=%.3f", 
		prefix, pos, time_pos, cache_time, cache_duration))
end

local function appendSubs(current_pos)
	debug_log("Starting appendSubs with current_pos: " .. current_pos)
	dump_timing_info("appendSubs", current_pos)

	-- Check if whisper command exists
	local whisper_check = io.popen("which whisper-cli")
	if not whisper_check then
		error_log("whisper-cli not found. Please install it first.")
		return current_pos
	end
	whisper_check:close()

	-- Check if model file exists
	local model_path = "/home/half-arch/models/ggml-base.bin"
	local f = io.open(model_path, "r")
	if not f then
		error_log("Whisper model not found at: " .. model_path)
		return current_pos
	end
	f:close()

	-- Check if input WAV file exists and has content
	local wav_file = io.open(TMP_WAV_PATH, "r")
	if not wav_file then
		error_log("Input WAV file not found at: " .. TMP_WAV_PATH)
		return current_pos
	end
	local wav_size = wav_file:seek("end")
	wav_file:close()
	
	if wav_size == 0 then
		error_log("Input WAV file is empty")
		return current_pos
	end

	-- Create initial SRT file if it doesn't exist
	if not io.open(TMP_SUB_PATH..'.srt', "r") then
		local init_srt = io.open(TMP_SUB_PATH..'.srt', "w")
		if init_srt then
			init_srt:write("1\n00:00:00,000 --> 00:00:01,000\n.\n\n")
			init_srt:close()
		end
	end

	-- Execute whisper command with error checking
	local whisper_cmd = WHISPER_CMD..' --output-srt -f "'..TMP_WAV_PATH..'" -of "'..TMP_SUB_PATH..'_append"'
	debug_log("Executing whisper command: " .. whisper_cmd)
	
	-- Create a temporary script to run the command
	local script_path = TMP_SUB_PATH..'_whisper.sh'
	local script_file = io.open(script_path, "w")
	if script_file then
		script_file:write("#!/bin/bash\n")
		script_file:write("set -e\n")
		script_file:write(whisper_cmd .. "\n")
		script_file:write('exit ${PIPESTATUS[0]}\n')
		script_file:close()
		os.execute("chmod +x " .. script_path)
		
		-- Run the script and capture output
		local handle = io.popen(script_path .. " 2>&1", "r")
		local output = handle:read("*a")
		local success, exit_type, code = handle:close()
		
		-- Clean up the temporary script
		os.remove(script_path)
		
		-- Check if the output file exists and adjust timings
		local append_file = io.open(TMP_SUB_PATH..'_append.srt', "r")
		if append_file then
			debug_log("Reading original subtitle file")
			local content = append_file:read("*a")
			append_file:close()
			
			debug_log("Original content: " .. content)
			
			if content and content ~= "" then
				-- Get video position for timing adjustment
				local video_time = mp.get_property_number("time-pos") * 1000
				if video_time == nil then
					video_time = current_pos
				end
				debug_log("Using video_time for adjustment: " .. video_time)
				
				-- Create a new file with adjusted timings
				local adjusted_file = io.open(TMP_SUB_PATH..'_adjusted.srt', "w")
				if adjusted_file then
					local sub_count = 0
					local adjusted_count = 0
					
					-- Split content into subtitle blocks
					local blocks = {}
					for block in content:gmatch("(%d+\n[%d:,]+ %-%-> [%d:,]+\n.-\n\n)") do
						table.insert(blocks, block)
					end
					
					debug_log("Found " .. #blocks .. " subtitle blocks")
					
					for _, block in ipairs(blocks) do
						local index, start_time, end_time, text = block:match("(%d+)\n(%d%d:%d%d:%d%d,%d%d%d) %-%-> (%d%d:%d%d:%d%d,%d%d%d)\n(.-)\n\n")
						
						if index and start_time and end_time and text then
							sub_count = sub_count + 1
							
							-- Log original times
							debug_log(string.format("Sub #%s - Original: %s --> %s", index, start_time, end_time))
							
							-- Convert and adjust times
							local start_ms = time_to_ms(start_time)
							local end_ms = time_to_ms(end_time)
							
							start_ms = start_ms + video_time
							end_ms = end_ms + video_time
							
							local adjusted_start = ms_to_time(start_ms)
							local adjusted_end = ms_to_time(end_ms)
							
							debug_log(string.format("Sub #%s - Adjusted: %s --> %s", index, adjusted_start, adjusted_end))
							
							-- Write adjusted subtitle
							adjusted_file:write(string.format("%d\n%s --> %s\n%s\n\n", 
								sub_count, adjusted_start, adjusted_end, text))
							adjusted_count = adjusted_count + 1
						end
					end
					
					adjusted_file:close()
					debug_log(string.format("Processed %d subtitles, adjusted %d entries", sub_count, adjusted_count))
					
					if adjusted_count > 0 then
						-- Replace the original append file with adjusted one
						os.execute('mv "'..TMP_SUB_PATH..'_adjusted.srt" "'..TMP_SUB_PATH..'_append.srt"')
						
						-- Append to main subtitle file
						os.execute('cat "'..TMP_SUB_PATH..'_append.srt" >> "'..TMP_SUB_PATH..'.srt"')
						debug_log("Appended adjusted subtitles to main file")
						
						-- Force subtitle reload
						mp.commandv('sub-reload')
						debug_log("Forced subtitle reload")
						
						return current_pos + chunk_dur
					else
						error_log("No subtitles were successfully adjusted")
					end
				end
			else
				error_log("Subtitle file was empty")
			end
		end
		
		error_log("Failed to process subtitle timings")
		return current_pos
	else
		error_log("Failed to create temporary script")
		return current_pos
	end
end

local function createSubs(current_pos)
	mp.commandv('show-text','Whisper: Generating initial subtitles')

	-- Get actual video time
	local video_time = mp.get_property_number("time-pos") * 1000
	if video_time == nil then
		video_time = current_pos
	end

	current_pos = appendSubs(video_time)

	-- Add subtitles and ensure they're visible
	mp.commandv('sub-remove')  -- Remove any existing subs first
	mp.commandv('sub-add', TMP_SUB_PATH..'.srt')
	mp.set_property("sub-delay", 0) -- Reset any subtitle delay
	mp.set_property("sub-visibility", "yes")
	mp.set_property("secondary-sub-visibility", "yes")

	return current_pos
end

local function createWAV(media_path, current_pos)
	debug_log("Creating WAV file from: " .. media_path .. " at position: " .. current_pos)
	
	-- For streams, try to ensure we have enough data cached
	if mp.get_property('demuxer-via-network') == 'yes' then
		local cache_time = mp.get_property_number('demuxer-cache-time') or 0
		if cache_time < (WAV_CHUNK_SIZE/1000) then
			debug_log("Cache too small, waiting for more data...")
			return false
		end
	end

	-- Construct ffmpeg command with more robust error handling
	local ffmpeg_cmd = string.format(
		'ffmpeg -hide_banner -loglevel error -y -ss %d -t %d -i %s -ar 16000 -ac 1 -c:a pcm_s16le "%s" 2>&1',
		current_pos/1000,
		WAV_CHUNK_SIZE/1000,
		media_path,
		TMP_WAV_PATH
	)
	
	debug_log("Running ffmpeg command: " .. ffmpeg_cmd)
	local handle = io.popen(ffmpeg_cmd, 'r')
	local output = handle:read('*all')
	local success, _, code = handle:close()
	
	if not success then
		error_log("FFmpeg failed with output: " .. output)
		return false
	end
	
	-- Verify the WAV file was created and has content
	local wav_file = io.open(TMP_WAV_PATH, "rb")
	if not wav_file then
		error_log("WAV file not created")
		return false
	end
	
	local size = wav_file:seek("end")
	wav_file:close()
	
	if size < 1024 then -- Less than 1KB is probably not valid audio
		error_log("WAV file too small: " .. size .. " bytes")
		return false
	end
	
	debug_log("Successfully created WAV file of size: " .. size .. " bytes")
	return true
end

local function runCache(current_pos)
	if not running then 
		debug_log("runCache: not running, returning")
		return 
	end
	
	dump_timing_info("runCache", current_pos)
	
	local cache_end = mp.get_property_number('demuxer-cache-time') or 0
	local new_pos = mp.get_property_number('time-pos') or 0
	new_pos = new_pos * 1000 -- Convert to ms
	
	if mp.get_property('demuxer-via-network') == 'yes' then
		debug_log(string.format("Stream mode - cache_end: %.3f, new_pos: %.3f", cache_end, new_pos/1000))
		
		if cache_end < (WAV_CHUNK_SIZE/1000 + 1) then
			debug_log("Cache too small: " .. cache_end .. " < " .. (WAV_CHUNK_SIZE/1000 + 1))
			mp.add_timeout(1.0, function() runCache(current_pos) end)
			return
		end
		
		-- Calculate new position
		local old_pos = current_pos
		current_pos = math.max(new_pos - 2*chunk_dur, current_pos)
		debug_log(string.format("Position update - old: %.3f, new: %.3f", old_pos/1000, current_pos/1000))
		
		-- Dump cache to temporary file
		debug_log(string.format("Dumping cache from %.3f to %.3f", current_pos/1000, (current_pos + chunk_dur)/1000))
		mp.commandv("dump-cache", current_pos/1000, (current_pos + chunk_dur)/1000, TMP_CACHE_PATH)
		
		mp.add_timeout(0.1, function()
			if createWAV(TMP_CACHE_PATH, 0) then
				current_pos = appendSubs(current_pos)
				debug_log("Successfully processed chunk, new position: " .. current_pos/1000)
			else
				debug_log("Failed to create WAV file")
			end
			mp.add_timeout(1.0, function() runCache(current_pos) end)
		end)
	else
		-- Original logic for local files
		if new_pos > (current_pos + chunk_dur) then
			current_pos = new_pos - (new_pos % chunk_dur)
			mp.commandv('show-text', 'Whisper: User skipped ahead, generating new subtitles starting at '..formatProgress(current_pos), 3000)
		end
		
		if createWAV(TMP_CACHE_PATH, 0) then
			current_pos = appendSubs(current_pos)
		end
		
		mp.add_timeout(0.1, function() runCache(current_pos) end)
	end
end

local function runLocal(media_path, file_length, current_pos)
	if running then
		-- Towards the end of the file lets just process the time left if smaller than CHUNK_SIZE
		local time_left = file_length - current_pos
		if (time_left < CHUNK_SIZE) then
			chunk_dur = time_left
		end

		if (time_left > 0) then
			if (createWAV(media_path..'*', current_pos)) then
				current_pos = appendSubs(current_pos)
			end

			-- Callback
			mp.add_timeout(0.1, function() runLocal(media_path, file_length, current_pos) end)
		else
			if SAVE_SRT then
				saveSubs(media_path)
			else
				mp.commandv('show-text', 'Whisper: Subtitles finished processing', 3000)
			end

			stop()
		end
	end
end

local function start()
	-- init vars
	local current_pos = mp.get_property_native('time-pos/full') * 1000
	chunk_dur = CHUNK_SIZE

	-- Set cache size for streams
	if mp.get_property('demuxer-via-network') == 'yes' then
		mp.set_property('demuxer-max-bytes', MAX_CACHE_SIZE)
		mp.set_property('cache-secs', 300)  -- Cache 5 minutes
	end

	-- use dump-cache for network streams and stdin
	if mp.get_property('demuxer-via-network') == 'yes' or mp.get_property('filename') == '-' then
		mp.set_property_bool("cache", true)
		mp.commandv("dump-cache", current_pos / 1000, (current_pos + chunk_dur) / 1000, TMP_CACHE_PATH)
		createWAV(TMP_CACHE_PATH, 0)
		current_pos = createSubs(current_pos)
		mp.add_timeout(0.1, function() runCache(current_pos) end)
	else
		local file_length = mp.get_property_number('duration/full') * 1000
		local media_path = mp.get_property('path')
		media_path = '"'..media_path..'"' -- fix spaces

		-- only local files can start subtitling from 00:00:00
		if START_AT_ZERO then
			current_pos = 0
		end

		createWAV(media_path, current_pos)
		current_pos = createSubs(current_pos)
		mp.add_timeout(0.1, function() runLocal(media_path, file_length, current_pos) end)
	end
end

local function toggle()
	debug_log("Toggle called")
	if running then
		mp.commandv('show-text', 'Whisper: Off')
		debug_log("Stopping whisper")
		stop()
	else
		running = true
		mp.commandv('show-text', 'Whisper: On')
		debug_log("Starting whisper")
		mp.register_event('end-file', stop)
		start()
	end
end

-- Modify the key binding setup to be more robust
local function setup_keybinding()
	debug_log("Setting up key bindings")
	-- Use pcall to handle potential errors
	local status, err = pcall(function()
		mp.add_key_binding('ctrl+a', 'whisper_subs', toggle)
	end)
	
	if not status then
		error_log("Failed to set up key bindings: " .. tostring(err))
	end
end

-- Call setup at script load
setup_keybinding()
