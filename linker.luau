local linker = {}
linker.__index = linker

local function read_cstring(b: buffer, offset: number): string
	local s = ''
	
	while true do
		local c = buffer.readu8(b, offset)
		
		if c == 0 then
			break
		end
		
		offset += 1
		s ..= string.char(c)
	end
	
	return s, #s
end

function linker:read_byte(): number
	return buffer.readu8(self.obj, self.tail)
end

function linker:read_word(): number
	return buffer.readu16(self.obj, self.tail)
end

function linker:read_string(): string
	return read_cstring(self.obj, self.tail)
end

function linker:advance_byte(): number
	local b = self:read_byte()
	self.tail += 1
	return b
end

function linker:advance_word(): number
	local b = self:read_word()
	self.tail += 2
	return b
end

function linker:advance_string(): string
	local str = self:read_string()
	self.tail += #str + 1
	return str
end

function linker:get_offset(obj: buffer, tbl: string)
	local bin_size = buffer.readu16(obj, 0)
	local sec_size = buffer.readu16(obj, 2)
	local glb_size = buffer.readu16(obj, 4)
	local imp_size = buffer.readu16(obj, 6)
	
	if tbl == 'section_tbl' then
		return 8 + bin_size
	elseif tbl == 'globals_tbl' then
		return 8 + bin_size + sec_size
	elseif tbl == 'redef_tbl' then
		return 8 + bin_size + sec_size + glb_size
	end
end

function linker:get_global_list(obj: buffer)
	local offset = self:get_offset(obj, 'globals_tbl')
	
	local global_count = buffer.readu16(obj, offset); offset += 2
	
	local global_list = {}
	
	for i = 0, global_count - 1 do
		local name, len =  read_cstring(obj, offset)
		offset += len + 1
		local sec, len = read_cstring(obj, offset)
		offset += len + 1
		local off = buffer.readu16(obj, offset)
		offset += 2
		
		global_list[name] = {section = sec, offset = off}
	end
	
	return global_list
end

function linker:get_sections(obj: buffer)
	local offset = self:get_offset(obj, 'section_tbl')
	
	local section_count = buffer.readu16(obj, offset); offset += 2
	local sections = {}
	
	for i = 0, section_count - 1 do
		local section_size = buffer.readu16(obj, offset); offset += 2
		local section_base = buffer.readu16(obj, offset); offset += 2
		local section_name, len = read_cstring(obj, offset); offset += len + 1

		table.insert(sections, {name = section_name, base = section_base, size = section_size})
	end
	
	return sections
end

function linker:get_redefs(obj: buffer)
	local offset = self:get_offset(obj, 'redef_tbl')
	local sym_count = buffer.readu16(obj, offset); offset += 2
	
	local redef_table = {}
	
	for i = 0, sym_count - 1 do
		local name, len = read_cstring(obj, offset); offset += len + 1
		local sec_name, len = read_cstring(obj, offset); offset += len + 1
		local is_import = buffer.readu8(obj, offset) == 1; offset += 1
		local count = buffer.readu16(obj, offset); offset += 2
		local bin_offset = buffer.readu16(obj, offset); offset += 2
		
		local redef_tbl = {
			name = name,
			section = sec_name,
			import = is_import,
			data = {},
			offset = bin_offset
		}
		
		for i = 0, count - 1 do
			local sym_offset = buffer.readu16(obj, offset); offset += 2
			local op_redef = buffer.readu8(obj, offset); offset += 1

			local a, b = bit32.btest(op_redef, 1), bit32.btest(op_redef, 2)

			table.insert(redef_tbl.data, {offset = sym_offset, a = a, b = b})
		end

		table.insert(redef_table, redef_tbl)
	end
	
	return redef_table
end

function linker:scan_obj_for_exported_symbol(obj: buffer, name: string)
	-- skip to global table
	local offset = buffer.readu16(obj, 0) + 2
	offset += buffer.readu16(obj, offset) + 2
	
	local count = buffer.readu16(obj, offset)
	
	for i = 0, count - 1 do
		local sym, len = read_cstring(obj, offset)
		offset += len + 1
		
		if sym == name then
			local section, len = read_cstring(obj, offset)
			offset += len + 1
			
			local sym_offset = buffer.readu16(obj, offset)
			
			return section, sym_offset
		end
	end
end

function linker:get_section_binary(obj: buffer, sec: string)
	local offset = buffer.readu16(obj, 0) + 2
	local sec_count = buffer.readu16(obj, offset + 2)
	offset += 4
	
	for i = 0, sec_count - 1 do
		local size = buffer.readu16(obj, offset)
		offset += 2
		local base = buffer.readu16(obj, offset)
		offset += 2
		local name, len = read_cstring(obj, offset)
		offset += len + 1
		
		if name == sec then
			local bin = buffer.create(size)
			buffer.copy(bin, 0, obj, base, size)
			return bin
		end
	end
end

function linker:emit_import(import_bin: buffer)
	local import_size = buffer.len(import_bin)
	local cur_size = self.binary_size
	local new_size = cur_size + import_size
	
	local new_bin = buffer.create(new_size)
	
	buffer.copy(new_bin, 0, self.binary, 0, cur_size)
	buffer.copy(new_bin, cur_size, import_bin, 0, import_size)
	
	self.binary = new_bin
	self.binary_size = new_size
	
	return cur_size
end

function linker:redo_instr(binary: buffer, offset: number, a_redef: boolean, b_redef: boolean, new_offset: number)
	local instr = buffer.readu16(binary, offset)
	local addr_mode = bit32.band(instr, 7)
	local data = bit32.band(bit32.rshift(instr, 3), 0xFF)
	local opcode = bit32.rshift(instr, 11)
	
	offset += 2
	
	if addr_mode == 0 and b_redef then
		buffer.writeu16(binary, offset, new_offset)
	elseif addr_mode == 3 and a_redef then
		buffer.writeu16(binary, offset, new_offset)
	elseif addr_mode == 6 then
		local a_size = bit32.btest(data, 1)
		local a_reg = bit32.btest(data, 8)
		
		if a_redef and not a_reg then
			buffer.writeu16(binary, offset, new_offset)
		end
		
		if not a_reg then
			offset += (a_size and 2 or 1)
		end
		
		if b_redef then
			buffer.writeu16(binary, offset, new_offset)
		end
	elseif addr_mode == 7 then
		local instr_type = bit32.band(data, 3)
		local a_size = bit32.btest(data, 8)
		local b_size = bit32.btest(data, 16)
		
		local a_reg = instr_type == 0 or instr_type == 1
		
		if a_redef and not a_reg then
			buffer.writeu16(binary, offset, new_offset)
			offset += 2
		elseif a_reg then
			offset += 1
		else
			offset += (a_size and 2 or 1)
		end
		
		if b_redef then
			buffer.writeu16(binary, offset, new_offset)
		end
	end
end

function linker:parse_flags()
	local flag_str = self.flags
	local parsed = {}
	local split = string.split(flag_str, ' ')
	
	for i = 1, #split do
		local v = split[i]
		local is_flag = string.sub(v, 1, 1) == '-'
		local flag_name
		
		if is_flag then
			flag_name = string.sub(v, 2)
		end
		
		if flag_name ~= nil then
			if flag_name == 'B' then -- base 
				i+= 1
				local base = split[i]
				i += 1
				
				parsed.base = tonumber(base)
			else
				error(`flag -{flag_name} is not supported`)
			end
		end
	end
	
	self.parsed_flags = parsed
end

function linker:init()
	self:parse_flags()
	
	self.binary_size = self:advance_word()
	self.binary = buffer.create(self.binary_size)
	
	buffer.copy(self.binary, 0, self.obj, 8, self.binary_size)
	
	local to_redef = self:get_redefs(self.obj)
	local imported_libs = {}
	
	for name, lib_bin in self.libs do
		local bin_size = buffer.readu16(lib_bin, 0)
		local bin = buffer.create(bin_size)
		buffer.copy(bin, 0, lib_bin, 8, bin_size)
		
		if imported_libs[name] then
			error(`{name} is already defined`)
		end
		
		local base = self:emit_import(bin)
		local globals = self:get_global_list(lib_bin)
		
		imported_libs[name] = {bin = bin, base = base, data = lib_bin, sections = self:get_sections(lib_bin), globals = self:get_global_list(lib_bin)}
		
		local lib_redefs = self:get_redefs(lib_bin)
		
		for i, v in lib_redefs do
			for a, b in v.data do
				b.offset += base
			end
			
			v.lib = name
			table.insert(to_redef, v)
		end
	end
	
	self.imported = imported_libs
	self.redef = to_redef
	self.sections = self:get_sections(self.obj)
	
	return self:finalize()
end

function linker:finalize()
	local binary = self.binary
	local parsed_flags = self.parsed_flags
	
	local base = parsed_flags.base or 0
	
	local all_instr_to_redo = {}
	
	-- rebase first
	
	for i, v in self.redef do
		if v.import then
			local lib, sym_offset, sym_section
			
			for _, l in self.imported do
				for a, b in l.globals do
					if a == v.name then
						lib = l
						sym_offset = b.offset
						sym_section = b.section
						break
					end
				end
			end
			
			if not lib then
				error(`imported {v.name}, but no library containing it was found (non global or not linked against)`)
			end
			
			local sec_base = 0
			
			for i, v in lib.sections do
				if v.name == sym_section then
					sec_base = v.base
					break
				end
			end
			
			local real_offset = lib.base + (sec_base + sym_offset)
			v.offset = real_offset + base
		else
			if not v.lib then
				local section = v.section
				local sec_base = 0
				
				for i, v in self.sections do
					if v.name == section then
						sec_base = v.base
						break
					end
				end
				
				v.offset += base + sec_base
			else
				local section = v.section
				local sec_base = 0
				
				local lib = self.imported[v.lib]
				
				for i, v in lib.sections do
					if v.name == section then
						sec_base = v.base + lib.base
						break
					end
				end
				
				v.offset += base + sec_base
			end
		end
	end
	
	for i, v in self.redef do
		local name, is_import, data = v.name, v.import, v.data
		
		for _, instr in data do
			table.insert(all_instr_to_redo, {
				offset = instr.offset,
				symbol = name,
				import = true,
				a = instr.a,
				b = instr.b,
				
				sym_offset = v.offset,
			})
		end
	end
	
	for i, v in all_instr_to_redo do
		self:redo_instr(binary, v.offset, v.a, v.b, v.sym_offset)
	end
	
	return binary
end

function link(obj: buffer, libs: {[string]: buffer}, flags: string)
	-- this below is outdated and im too lazy to update it
	-- build obj file with section data, global data, and imports first two bytes of the file would be the total size of binary img in bytes
	-- after that is section data, a table indicating a section's size, then a name null terminated
		-- 2 bytes before entries for the section count
	-- each entry is:
		-- 2 bytes for the size of the section
		-- then a null terminated name of this section
	-- after that size is a table of symbols exposed globally, with first 2 bytes indicating the count of symbols, each entry:
		-- symbol name (null terminated)
		-- null terminated section name
		-- two bytes indicating the offset from that section
	-- then finally a symbol table, indicating which instructions have symbols that must be imported / redefined; ONLY. those.
		-- symbol name, null terminated, 1 byte indicating if this is an imported symbol, then 2 bytes indicating the size of the instruction table
		-- 3 byte entries for the instruction table:
			-- first 2 bytes indicating the actual binary object offset for the instruction
			-- 1 extra byte indicating which operand needs redefinition:
				-- bit 0 = a
				-- bit 1 = b
				-- both can be set at the same time
	-- the linker will take this entire object file, and resolve each symbols final address, importing the necessary modules as needed, and building a final binary
	
	--[[
		the goal for the linker is to enable dynamic basing of a file whereever specified.
		for example a program before the linker would have to specify exactly where to write code with #org, and the binary size would expand to
		pad memory with zeroes to reach that org
		
		with the linker, binaries can be unpadded and placed anywhere in memory and still run as expected!
		
		another goal of the linker is to enable importing of modules / libraries
		the program would specify in an import table which symbols are imports, and would find those symbols within the given lib files in arg 2
		if a symbol is found matching the imported one, the section in which that symbol is contained is placed into the binary (the entire section)
		then the instructions pertaining to that symbol are rewritten to handle the new memory address of that symbol
		
		if the symbol is not found, and it is an import, an error is thrown
		
		all instructions that use a symbol are within the symbol table, under the symbol entry in an instruction table
	]]
	
	local self = setmetatable({
		obj = obj,
		libs = libs,
		
		len = buffer.len(obj),
		tail = 0,
		binary_size = 0,
		section_tbl_size = 0,
		global_tbl_size = 0,
		flags = flags or '',
		import_tbl_size = 0,
	}, linker)
	
	local bin = self:init()
	
	return bin
end

return link
