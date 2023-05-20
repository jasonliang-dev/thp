package main

import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strings"
import "core:runtime"
import lua "vendor:lua/5.4"

g_echobuf: strings.Builder

Scanner :: struct {
	data: string,
	pos: int,
	end: int,
}

make_scanner :: proc(str: string) -> (s: Scanner) {
	s.data = str
	s.end = len(str)
	s.pos = 0
	return
}

scanner_match :: proc(s: ^Scanner, str: string) -> bool {
	matches := (s.end - s.pos >= len(str)) && (s.data[s.pos : s.pos + len(str)] == str)
	if matches {
		s.pos += len(str)
	}

	return matches
}

scanner_next :: proc(s: ^Scanner) -> string {
	is_whitespace :: proc(c: u8) -> bool {
		switch c {
		case '\n', '\r', '\t', ' ':
			return true
		case:
			return false
		}
	}

	for s.pos < s.end && is_whitespace(s.data[s.pos]) {
		s.pos += 1
	}

	begin := s.pos

	if s.pos == s.end {
		return ""
	}

	for s.pos < s.end && !is_whitespace(s.data[s.pos]) {
		s.pos += 1
	}

	return s.data[begin:s.pos]
}

transpile :: proc(filename: string) -> (lua_code: string, err: cstring) {
	contents, ok := os.read_entire_file(filename)
	if !ok {
		err = "failed to read file"
		return
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "?>")
	strings.write_bytes(&builder, contents)
	strings.write_string(&builder, "<?lua")

	out := strings.builder_make()

	scan := make_scanner(strings.to_string(builder))

	for scan.pos < scan.end {
		if scanner_match(&scan, "?>") {
			strings.write_string(&out, "echo([=[")
		} else if scanner_match(&scan, "<?lua") {
			strings.write_string(&out, "]=])")
		} else {
			strings.write_byte(&out, scan.data[scan.pos])
			scan.pos += 1
		}
	}

	lua_code = strings.to_string(out)
	return
}

template :: proc(L: ^lua.State, filename: string) -> (tmpl: string, err: cstring) {
	code: string
	code, err = transpile(filename)
	if err != "" {
		return
	}

	name := strings.clone_to_cstring(filename, context.temp_allocator)

	status := lua.L_loadbuffer(L, raw_data(code), len(code), name)
	if status != .OK {
		err = lua.L_checkstring(L, -1)
		return
	}

	res := lua.pcall(L, 0, lua.MULTRET, 0)
	if res != 0 {
		err = lua.L_checkstring(L, -1)
		return
	}

	tmpl = strings.to_string(g_echobuf)
	return
}

send :: proc(client: net.TCP_Socket, status: string, type: string, body: string) -> net.Network_Error {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, fmt.tprintf("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: ", status, type))
	strings.write_string(&sb, fmt.tprint(len(body)))
	strings.write_string(&sb, "\r\n\r\n")
	strings.write_string(&sb, body)
	net.send(client, sb.buf[:]) or_return
	return nil
}

send_status :: proc(client: net.TCP_Socket, status: string) -> net.Network_Error {
	return send(client, status, "text/plain", status)
}

handle_request :: proc(L: ^lua.State, sock: net.TCP_Socket) -> net.Network_Error {
	client, source := net.accept_tcp(sock) or_return
	defer net.close(client)

	buf: [2048]u8
	bytes := net.recv(client, buf[:]) or_return

	scan := make_scanner(string(buf[:]))
	method := scanner_next(&scan)
	if method != "GET" {
		send_status(client, "405 Method Not Allowed") or_return
		return nil
	}

	location := scanner_next(&scan)
	location = location[1:]
	if location == "" {
		location = "index.html"
	}

	if !os.is_file(location) {
		send(client, "404 Not Found", "text/plain", fmt.tprintf("'%s' Not Found", location)) or_return
		return nil
	}

	if strings.has_suffix(location, ".html") {
		strings.builder_reset(&g_echobuf)
		tmpl, err := template(L, location)
		if err != "" {
			send(client, "500 Internal Server Error", "text/plain", string(err)) or_return
			return nil
		}

		send(client, "200 OK", "text/html", tmpl) or_return
	} else {
		contents, ok := os.read_entire_file(location)
		if !ok {
			send_status(client, "500 Internal Server Error") or_return
			return nil
		}

		type: string
		if strings.has_suffix(location, ".css") {
			type = "text/css"
		} else if strings.has_suffix(location, ".js") {
			type = "text/javascript"
		} else if strings.has_suffix(location, ".png") {
			type = "image/png"
		} else if strings.has_suffix(location, ".jpg") {
			type = "image/jpeg"
		} else if strings.has_suffix(location, ".jpeg") {
			type = "image/jpeg"
		} else if strings.has_suffix(location, ".ttf") {
			type = "font/ttf"
		} else if strings.has_suffix(location, ".weba") {
			type = "audio/webm"
		} else if strings.has_suffix(location, ".webm") {
			type = "video/webm"
		} else {
			type = "text/plain"
		}

		send(client, "200 OK", type, string(contents)) or_return
	}

	return nil
}

serve :: proc(L: ^lua.State, dir: string, addr: string) -> net.Network_Error {
	os.change_directory(dir)

	ep := net.resolve_ip4(addr) or_return
	sock := net.listen_tcp(ep) or_return
	defer net.close(sock)

	fmt.printf("serving '%s' on %v\n", dir, addr)

	for {
		handle_request(L, sock)
	}
}

usage :: proc() {
	fmt.eprintf("usage: %s command [args]\n", os.args[0])
	fmt.eprintln(`commands:
	serve <dir> [address]    run development server for given directory
	build <file>             build a single template file
	build_dir <from> <to>    build all files in a directory`)
}

main :: proc() {
	L := lua.L_newstate()
	defer lua.close(L)

	lua.L_openlibs(L)

	lua.pushcfunction(L, proc "cdecl" (L: ^lua.State) -> i32 {
		context = runtime.default_context()
		str := lua.L_checkstring(L, 1)
		strings.write_string(&g_echobuf, string(str))
		return 0
	})
	lua.setglobal(L, "echo")

	lua.pushcfunction(L, proc "cdecl" (L: ^lua.State) -> i32 {
		context = runtime.default_context()

		top := lua.gettop(L)

		c_filename := lua.L_checkstring(L, 1)
		filename := string(c_filename)

		code: string
		if strings.has_suffix(filename, ".html") {
			err: cstring
			code, err = transpile(filename)
			if err != "" {
				return i32(lua.L_error(L, "error while importing '%s': %s", c_filename, err))
			}
		} else if strings.has_suffix(filename, ".lua") {
			contents, ok := os.read_entire_file(filename)
			if !ok {
				return i32(lua.L_error(L, "cannot read file '%s'", c_filename))
			}
			code = string(contents)
		}

		status := lua.L_loadbuffer(L, raw_data(code), len(code), c_filename)
		if status != .OK {
			return i32(lua.error(L))
		}

		res := lua.pcall(L, 0, lua.MULTRET, 0)
		if res != 0 {
			return i32(lua.error(L))
		}

		args := lua.gettop(L) - top
		return args
	})
	lua.setglobal(L, "import")

	if len(os.args) < 3 {
		usage()
		return
	}

	switch os.args[1] {
	case "serve":
		if len(os.args) != 3 && len(os.args) != 4 {
			usage()
			return
		}

		dir := os.args[2]

		addr: string
		if len(os.args) == 4 {
			addr = os.args[3]
		} else {
			addr = "localhost:8080"
		}

		err := serve(L, dir, addr)
		if err != nil {
			fmt.eprintln(err)
		}
	case "build":
		if len(os.args) != 3 {
			usage()
			return
		}

		strings.builder_reset(&g_echobuf)
		tmpl, err := template(L, os.args[2])
		if err != "" {
			fmt.eprintln(string(err))
			return
		}

		fmt.println(tmpl)
	case "build_dir":
		if len(os.args) != 4 {
			usage()
			return
		}

		errno: os.Errno

		from: os.File_Info
		to: os.File_Info

		from, errno = os.stat(os.args[2])
		to, errno = os.stat(os.args[3])

		errno = os.remove_directory(to.fullpath)
		if errno != 0 {
			fmt.eprintln("failed to remove: ", to.fullpath)
		}

		errno = os.make_directory(to.fullpath)

		fd: os.Handle
		fd, errno = os.open(from.fullpath)
		if errno != 0 {
			fmt.eprintln("failed to open: ", from.fullpath)
			return
		}
		defer os.close(fd)

		fi: []os.File_Info
		fi, errno = os.read_dir(fd, 0)
		if errno != 0 {
			fmt.eprintf("failed to read dir: %v", from.fullpath)
			return
		}

		os.change_directory(from.fullpath)

		for info in fi {
			fmt.println(info.name)

			dst := fmt.tprintf("%s/%s", to.fullpath, info.name)

			if info.is_dir {
				continue
			}

			if info.name[0] == '_' {
				continue
			}

			if strings.has_suffix(info.name, ".html") {
				strings.builder_reset(&g_echobuf)
				tmpl, err := template(L, info.fullpath)
				if err != "" {
					fmt.eprintln(string(err))
					return
				}

				ok := os.write_entire_file(dst, transmute([]u8)tmpl)
				if !ok {
					fmt.eprintln("failed to write file: ", dst)
				}
			} else {
				contents, ok := os.read_entire_file(info.fullpath)
				if !ok {
					fmt.eprintln("failed to read file: ", info.fullpath)
					return
				}

				ok = os.write_entire_file(dst, contents)
				if !ok {
					fmt.eprintln("failed to write file: ", dst)
				}
			}
		}
	case:
		usage()
	}
}