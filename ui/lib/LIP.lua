--[[
	Copyright (c) 2012 Carreras Nicolas
	
	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:
	
	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.
	
	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
--]]
--- Lua INI Parser.
-- It has never been that simple to use INI files with Lua.
--@author Dynodzzo

-- Edits for MAUI
-- LIP.load will load keys with empty values
---- This is to support reading LemonsInfo INI which stores lists like FireImmune, etc with k/v like "mobname="
-- LIP.save writes data using the defined schema for the macro, to keep a user friendly ordering of keys
-- !!! DO NOT OVERWRITE THIS WITH OTHER LIP.lua, OR OVERWRITE OTHER LIP.lua WITH THIS !!!

local LIP = {};

--- Returns a table containing all the data from the INI file.
--@param fileName The name of the INI file to parse. [string]
--@return The table containing all data from the INI file. [table]
function LIP.load(fileName, initNilValues)
	assert(type(fileName) == 'string', 'Parameter "fileName" must be a string.');
	local file = assert(io.open(fileName, 'r'), 'Error loading file : ' .. fileName);
	local data = {};
	local section;
	for line in file:lines() do
		local tempSection = line:match('^%[([^%[%]]+)%]$');
		if(tempSection)then
			section = tonumber(tempSection) and tonumber(tempSection) or tempSection;
			data[section] = data[section] or {};
		end
		--local param, value = line:match('^([%w|_]+)%s-=%s-(.+)$');
		-- include keys with spaces
		--local param, value = line:match("^([%w|_'.%s-]+)=%s-(.+)$");
		-- read keys with no value
		local param, value = line:match("^([%w|_'.%s-]+)=(.-)$");
		if(param and value ~= nil)then
			if not section then
				print('\at[\ax\ayMAUI\ax\at]\ax \arERROR: Invalid section header in INI file.\ax')
				return {error='Invalid section header in INI file.'}
			end
			if(tonumber(value))then
				value = tonumber(value);
			elseif(value == 'true')then
				value = true;
			elseif(value == 'false')then
				value = false;
			end
			if(tonumber(param))then
				param = tonumber(param);
			end
			data[section][param] = value;
		elseif param and initNilValues then
			if not section then
				print('\at[\ax\ayMAUI\ax\at]\ax \arERROR: Invalid section header in INI file.\ax')
				return {error='Invalid section header in INI file.'}
			end
			data[section][param] = 0
		end
	end
	file:close();
	return data;
end

local function WriteKV(contents, key, value)
	if value == true then
		value = 1
	elseif value == false then
		value = 0
	end
	return contents .. ('%s=%s\n'):format(key, tostring(value))
end

--- Saves all the data from a table to an INI file.
--@param fileName The name of the INI file to fill. [string]
--@param data The table containing all the data to store. [table]
function LIP.save(fileName, data, schema)
	assert(type(fileName) == 'string', 'Parameter "fileName" must be a string.');
	assert(type(data) == 'table', 'Parameter "data" must be a table.');
	local file = assert(io.open(fileName, 'w+b'), 'Error loading file :' .. fileName);
	local contents = '';

	-- iterate over sections from the schema so we can write the INI in a user friendly order
	for _, sectionKey in ipairs(schema.Sections) do
		-- proceed if we have data for the section
		if data[sectionKey] and next(data[sectionKey]) ~= nil then
			-- write the section key
			contents = contents .. ('[%s]\n'):format(sectionKey);
			if schema[sectionKey] then
				-- if we define controls for the schema section, like BuffsOn, BuffsCOn, write those first
				if schema[sectionKey]['Controls'] then
					for k,v in pairs(schema[sectionKey]['Controls']) do
						contents = WriteKV(contents, sectionKey..k, data[sectionKey][sectionKey..k])
					end
				end
				-- If we define properties for the schema section, write each of those next
				if schema[sectionKey]['Properties'] then
					for k,v in pairs(schema[sectionKey]['Properties']) do
						-- If the property is a list, like XYZ1, XYZ2, then iterator over XYZSize, writing XYZ# and XYZCond#
						if v['Type'] == 'LIST' then
							if data[sectionKey][k..'Size'] then
								contents = contents .. ('%s=%s\n'):format(k..'Size', tostring(data[sectionKey][k..'Size']));
								for i=1,data[sectionKey][k..'Size'] do
									if data[sectionKey][k..tostring(i)] ~= nil then
										contents = WriteKV(contents, k..tostring(i), data[sectionKey][k..tostring(i)])
									end
									if data[sectionKey][k..'Cond'..tostring(i)] ~= nil then
										contents = WriteKV(contents, k..'Cond'..tostring(i), data[sectionKey][k..'Cond'..tostring(i)])
									end
								end
							end
						else
							-- If the property is not a list, just write it
							if data[sectionKey][k] ~= nil then
								contents = WriteKV(contents, k, data[sectionKey][k])
							end
						end
					end
				end
				for k,value in pairs(data[sectionKey]) do
					-- Write any remaining keys which are not defined in the schema for the section
					if not contents:find(k..'=') then
						contents = WriteKV(contents, k, value)
					end
				end
			else
				-- The section has no properties defined in the schema, just write them
				for k, v in pairs(data[sectionKey]) do
					contents = WriteKV(contents, k, v)
				end
			end
			contents = contents .. '\n';
		end
	end
	file:write(contents);
	file:close();
end

--- Saves all the data from a table to an INI file.
--@param fileName The name of the INI file to fill. [string]
--@param data The table containing all the data to store. [table]
function LIP.save_simple(fileName, data)
	assert(type(fileName) == 'string', 'Parameter "fileName" must be a string.');
	assert(type(data) == 'table', 'Parameter "data" must be a table.');
	local file = assert(io.open(fileName, 'w+b'), 'Error loading file :' .. fileName);
	local contents = '';
	for section, param in pairs(data) do
		contents = contents .. ('[%s]\n'):format(section);
		-- sort the keys before writing the file
		local keys = {}
		for k, v in pairs(param) do table.insert(keys, k) end
		table.sort(keys)

		for _, k in ipairs(keys) do
			contents = contents .. ('%s=%s\n'):format(k, tostring(param[k]));
		end
		contents = contents .. '\n';
	end
	file:write(contents);
	file:close();
end

return LIP;