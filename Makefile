parser:
	ocamlbuild -pkgs str parser.byte
main:
	ocamlbuild -pkgs oUnit,yojson,str,ANSITerminal,cohttp.lwt main.byte && ./main.byte
server:
	ocamlbuild -pkgs yojson,cohttp.lwt,extlib,str,unix server.byte && ./server.byte
renderer:
	ocamlbuild -pkgs oUnit,yojson,str,ANSITerminal renderer.byte
dataOperations:
	ocamlbuild -pkgs extlib,str,unix dataOperations.byte
test_data:
	ocamlbuild -pkgs extlib,str,unix,oUnit test_dataOperations.byte && ./test_dataOperations.byte
test_parser:
	ocamlbuild -pkgs extlib,str,unix,oUnit test_parser.byte && ./test_parser.byte