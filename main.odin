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

template :: proc(L: ^lua.State, filename: string) -> cstring {
	strings.builder_reset(&g_echobuf)

	contents, ok := os.read_entire_file_from_filename(filename)
	if !ok {
		return ""
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

	name := strings.clone_to_cstring(filename, context.temp_allocator)

	str := strings.to_string(out)
	status := lua.L_loadbuffer(L, raw_data(str), len(str), name)
	if status != .OK {
		return lua.L_checkstring(L, -1)
	}

	res := lua.pcall(L, 0, lua.MULTRET, 0)
	if res != 0 {
		return lua.L_checkstring(L, -1)
	}

	return ""
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

serve :: proc(L: ^lua.State) -> net.Network_Error {
	addr :: "localhost:8080"

	ep := net.resolve_ip4(addr) or_return

	sock := net.listen_tcp(ep) or_return
	defer net.close(sock)

	fmt.printf("listening (%v)\n", addr)

	for {
		client, source := net.accept_tcp(sock) or_return
		defer net.close(client)

		buf: [2048]u8
		bytes := net.recv(client, buf[:]) or_return

		err := template(L, "index.html")
		if err != "" {
			send(client, "500 Internal Server Error", "text/plain", string(err)) or_return
			continue
		}

		send(client, "200 OK", "text/html", strings.to_string(g_echobuf)) or_return
	}
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

	err := serve(L)
	if err != nil {
		fmt.eprintln(err)
	}
}