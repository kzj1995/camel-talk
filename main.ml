open Yojson
open Client
open Parser
open Renderer
open Lwt

type current_state = {
  mutable current_org : string option;
  mutable current_channel : string option;
  mutable current_user : string;
  mutable current_screen : Parser.screen;
  mutable logged_out : bool;
  mutable current_line : int;
  mutable message : string
}

(** represents the current user typed input *)
let current_input_stack = ref []

(** represents the server hostname that the client API will contact*)
let server_addr = ref ""

(**
 * [escape_char c] escapes the character [c] and provides compatibility
 * with JSON strings
 *)
let escape_char c =
  if c = '\\' then
    "\\"
  else if c = '\'' then
   "'"
  else if c = '\\' then
   "\\"
  else
    Char.escaped c

(**
 * [escape_str s] escapes the string [s] and provides compatibility with
 * JSON strings
 *)
let escape_str s =
  if s = "\\" then
    "\\\\"
  else if s = "\"" then
    "\\\""
  else if s = "\\'" then
    "'"
  else
     s

(**
 * [check_special c] checks to see if char [c] is a possible pecial arrow
 * character, and then mutates the stack to get rid of string if needed
 *)
let check_special (c:char) : bool =
  if c = 'A' || c = 'B' || c = 'C' || c = 'D' then
  begin
    match !current_input_stack with
    | a::b::t when (a = escape_char '[' && b = escape_char '\027') -> (current_input_stack:=t; true)
    | _ -> false
  end
  else false

let rec main (st : current_state) : (unit Lwt.t) =
	Lwt_io.read_char (Lwt_io.stdin) >>=
  (
  fun c ->
  (
  if c = '\127' then
    match !current_input_stack with
    | [] -> main st
    | h::t ->
      (current_input_stack := t;
      main st)
  else if check_special c then
    main st
  else if c != '\n' then
    (current_input_stack := (escape_char c)::!current_input_stack;
    main st)
  else
    let input_stack = List.map escape_str !current_input_stack in
    let s = String.concat "" (List.rev input_stack) in
    let () = (current_input_stack := []) in
    match text_to_message s st.current_screen with
    | CIllegal ->
    	(st.message <- "Illegal command"); main st
    | CCreate s -> (
      (
      match st.current_screen with
      | Organizations -> (
          (Client.create_organization st.current_user s !server_addr)
          >>= (fun r ->
          (st.message <- r.message); main st)
      )
      | Channels -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o ->
          (Client.create_channel st.current_user o s !server_addr) >>=
          (fun r -> (st.message <- r.message); main st)
      )
      | Messages -> failwith "shouldn't happen"
      )
    )
    | CDelete s -> (
      match st.current_screen with
      | Organizations ->
          (Client.delete_organization st.current_user s !server_addr)
          >>= (fun r ->
          (st.message <- r.message);
          (
            match r.status with
            | "failure" -> main st
            | "success" ->
              if not (Some s = st.current_org) then main st
              else (st.current_org <- None;
              main st)
            | _ -> failwith "unknown response"
          )
        )
      | Channels -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o ->
          (Client.delete_channel st.current_user o s !server_addr) >>= fun r ->
          (st.message <- r.message);
          (
            match r.status with
            | "failure" -> main st
            | "success" -> (
              if not (Some s = st.current_channel) then
                main st
              else (
                st.current_channel <- None;
                main st
              )
            )
            | _ -> failwith "unknown response"
        )
      )
      | Messages -> failwith "shouldn't happen"
    )
    | CSwitch s -> (
      match st.current_screen with
      | Organizations -> (
          (Client.get_org_info st.current_user s !server_addr)
          >>= fun (stat,r) ->
          match stat with
          | "failure" -> (
            (st.message <- "Not a valid command"); main st
          )
          | "success" -> (
            (st.message <- ("Switched into organization \""^s^"\""));
            st.current_org <- Some s;
            st.current_screen <- Channels;
            main st
          )
          | _ -> failwith "unknown response"
        )
      | Channels -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o -> (
          (Client.get_messages st.current_user s o 0 !server_addr)
          >>= fun (stat, r) ->
          match stat with
          | "failure" -> (
            (st.message <- "Not a valid switch"); main st
          )
          | "success" -> (
            (st.message <- ("Switched into channel \""^s^"\""));
            st.current_channel <- Some s;
            st.current_screen <- Messages;
            main st
          )
          | _ -> failwith "unknown response"
        )
      )
      | Messages -> failwith "shouldn't happen"
    )
    | CSimpleMessage s -> (
      match st.current_screen with
      | Messages -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o -> (
          match st.current_channel with
          | None -> failwith "shouldn't happen"
          | Some c -> (send_message st.current_user c o "simple" 
            (`Assoc [("content", `String s)]) !server_addr) >>=
            fun r -> main st
        )
      )
      | _ -> failwith "shouldn't happen"
    )
    | CReminderMessage (s, i) -> (
      match st.current_screen with
      | Messages -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o -> (
          match st.current_channel with
          | None -> failwith "shouldn't happen"
          | Some c -> (send_message st.current_user c o "reminder" 
            (`Assoc [("content", `String s);
            ("time", `String (string_of_int i))]) !server_addr) >>=
            fun r -> main st
        )
      )
      | _ -> failwith "shouldn't happen"
    )
    | CPollMessage (s, xs) -> (
      match st.current_screen with
      | Messages -> (
        match st.current_org with
        | None -> failwith "shouldn't happen"
        | Some o -> (
          match st.current_channel with
          | None -> failwith "shouldn't happen"
          | Some c -> send_message st.current_user c o "poll"
            (`Assoc [
              ("content", `String s);
              ("options", `List (List.map (fun x -> `Assoc [("option",
              `String x); ("count", `Int 0)]) xs))
            ]) !server_addr) >>=
            fun r -> main st
      )
      | _ -> failwith "shouldn't happen"
    )
    | CBack -> (
      match st.current_screen with
      | Organizations ->
        (st.message <- "Can't go out of organization screen."); main st
      | Channels ->
        st.current_screen <- Organizations;
        st.current_channel <- None;
        main st
      | Messages ->
        st.current_screen <- Channels;
        main st
    )
    | CQuit -> ( st.message <- "Goodbye"; ignore (Sys.command "clear");
      Lwt.return ()
      )
    | CInvite (user_to_join, orgid) -> (
      (invite user_to_join orgid st.current_user !server_addr) >>=
      fun r -> (st.message <- r.message); main st
    )
    | CLeave (user_to_leave, orgid) -> (
      (leave user_to_leave orgid st.current_user !server_addr) >>=
      fun r -> (st.message <- r.message); main st
    )
    | CVote (poll, choice) -> begin
      match (st.current_org, st.current_channel) with
      | (Some orgid, Some chanid)->
        (vote orgid chanid poll choice !server_addr) >>=
        fun r ->
        (st.message <- r.message); main st
      | (_, _)-> failwith "shouldn't happen"
      end
    | CScrollUp -> st.current_line <- st.current_line + 10 ; main st
    | CScrollDown -> st.current_line <- st.current_line - 10 ; main st
    | CCreateDirectMessage s ->
        (
        match st.current_screen with
        | Organizations ->
          (st.message <- "Not a valid command in this screen."); main st
        | Channels -> (
          match st.current_org with
          | None -> failwith "shouldn't happen"
          | Some o ->
            let channel_name = "directmessage@" ^
            (if (String.compare st.current_user s) <= 0  then
              st.current_user ^ "@" ^ s
            else
              s ^ "@" ^ st.current_user
            ) in
            (Client.create_channel st.current_user o channel_name !server_addr)
            >>=
            (fun r -> (st.message <- r.message); main st)
        )
        | Messages -> failwith "shouldn't happen"
        )
    | CDirectMessage s ->
        (
        match st.current_screen with
        | Organizations ->
          (st.message <- "Not a valid command in this screen."); main st
        | Channels -> (
          match st.current_org with
          | None -> failwith "shouldn't happen"
          | Some o ->
            let channel_name = "directmessage@" ^
            (if (String.compare st.current_user s) <= 0  then
              st.current_user ^ "@" ^ s
            else
              s ^ "@" ^ st.current_user
            ) in
            (Client.get_messages st.current_user channel_name o 0 !server_addr)
            >>= fun (stat, r) ->
            match stat with
            | "failure" -> (
              (st.message <- "Not a valid switch"); main st
            )
            | "success" -> (
              (st.message <- ("Switched into direct message with \""^s^"\""));
              st.current_channel <- Some channel_name;
              st.current_screen <- Messages;
              main st
            )
          | _ -> failwith "unknown response"
        )
        | Messages -> failwith "shouldn't happen"
        )
    | CHelp ->
      (st.message <-
      "Help info:
      While in ORGANIZATION/CHANNEL screen:
      #create <name> : creates a new organization/channel.
      Must be unique.
      #delete <name> : deletes an existing organization/channel.
      Must be an admin.
      <existing organization name> : switches into organization/channel.
      #invite <username> <org name> : invites another user to join
      the specified organization. (only for organization screen)
      #leave <username> <organization name> : kicks out the user from the
      specified organization. (only for organization screen)
      #quit : quits the application
      #back : goes out of channel screen into the organization screen
      While in CHANNEL screen:
      #create_direct_message <username> : creates a direct message channel
      with the specified user in the current organization
      #direct_message <username> : enters a direct message channel with the
      specified user in the current organization
      While in MESSAGE screen:
      <anything not starting with #> : sends a message containing only text
      #set_reminder <minutes> <text> : sets a reminder that sends a message with
      the specified text in the specified number of minutes
      after the specified amount of time has elapsed.
      #set_poll [<option1>,<option2>...] <question> : sets a poll with options
      that other users of the channel can vote on.
      #vote <pollname> <optionname> : votes on an option from an existing poll.
      #scrollup, #scrolldown: scrolls the message list up or down respectively.
      #back and #quit: same as above."
      ); main st
    )
  )

and login () =
  ANSITerminal.(print_string [Bold; blue]
  	"\nTo log in, type in your username, then password.");
  ANSITerminal.(print_string [Bold; green]
  	"\nUsername: ");
  let username = read_line () in
  ANSITerminal.(print_string [Bold; green]
  	"Password: ");
  let password = read_line () in
  let r = Lwt_main.run (login_user username password !server_addr) in
    if r.status = "success" then (
    ANSITerminal.(print_string [Bold; green]
    "Success!\n");
    flush_all ();
    let st =  {
       current_org = None;
       current_channel = None;
       current_user = username;
       current_screen = Organizations;
       logged_out = false;
       current_line = 0;
       message = "Hello, "^username^". Type \"#help\" to see commands."
    } in
    Sys.(set_signal sigint Signal_ignore);
    Sys.(set_signal sigquit Signal_ignore);
    return (run_app_threads st)
    )
  else
  (
    ANSITerminal.(print_string [Bold; blue]
  	"\nNot a valid username and password pair\nWant to register? (y/n) Or, type \"exit\" to exit\n");
    ANSITerminal.(print_string [Blink] "> ");
    match read_line () with
    | "exit" -> return (ignore (exit 0))
    | "y" -> register ()
    | _ -> login ()
  )

and register () =
  ANSITerminal.(print_string [Bold; blue]
  	"\nTo register, type in your desired username, then desired password.");
  ANSITerminal.(print_string [Bold; green] "\nUsername: ");
  let username = read_line () in
    ANSITerminal.(print_string [Bold; green] "Password: ");
  let password = read_line () in
  let r = Lwt_main.run (register_user username password !server_addr) in
  if r.status = "success" then (
    ANSITerminal.(print_string [Bold; green] "Success!\n");
    flush_all ();
    let st =  {
       current_org = None;
       current_channel = None;
       current_user = username;
       current_screen = Organizations;
       logged_out = false;
       current_line = 0;
       message = "Hello, "^username^". Type \"#help\" to see commands."
    } in
    Sys.(set_signal sigint Signal_ignore);
    Sys.(set_signal sigquit Signal_ignore);
    return (run_app_threads st)
  )
  else (
    ANSITerminal.(print_string [Bold; blue]
      "An error occured. Please register again.");
    register ()
  )

(**
 * [run_app_threads st] starts up the threads necessary for the application
 * loop to function properly (each thread has access to the application
 * state [st])
 * 
 * Note: in order to synchronize the draw update/rendering with standard input,
 * we use a strategy below of setting the standard input to not require
 * the new line character for reading and also setting the echo to false. We
 * learned the API for this from http://stackoverflow.com/questions/13410159/how
 * -to-read-a-character-in-ocaml-without-a-return-key
 *)
and run_app_threads st =
  let termio = Unix.tcgetattr Unix.stdin in
  let () = Unix.tcsetattr Unix.stdin Unix.TCSADRAIN {termio with
  Unix.c_icanon = false; Unix.c_echo = false} in
  let () = ((Lwt_main.run (Lwt.pick [draw_update st; main st]))) in
  Unix.tcsetattr Unix.stdin Unix.TCSADRAIN {termio with
  Unix.c_icanon = true; Unix.c_echo = true}


and draw_update c =
  let print_persist () =
  ANSITerminal.(print_string []
" .d8888b.                                   888 888             888 888
d88P  Y88b                                   888 888             888 888
888    888                                   888 888             888 888
888         8888b.  88888b.d88b.    888888   888 888888  8888b.  888 888  888
888             88b 888  888  88b  88    88  888 888         88b 888 888 .88P
888    888 .d888888 888  888  888  88888888  888 888    .d888888 888 888888K
Y88b  d88P 888  888 888  888  888  88        888 Y88b.  888  888 888 888  88b
  Y8888P    Y888888 888  888  888   888888    888   Y888  Y888888 888 888  888
"
  );
  ANSITerminal.(print_string [magenta]
  ("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"^
  (c.message)
  ^"\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"))
  in
  Lwt_unix.sleep 0.1 >>= (fun () ->
  match c.current_screen with
  | Organizations ->
      if c.logged_out then Lwt.return ()
      else
        (get_user_organizations c.current_user !server_addr) >>=
        fun (_,response_json) ->
        (ANSITerminal.(erase Above);
        ANSITerminal.(move_cursor (-100) 0);
        print_persist ();
        render_organizations_list response_json;
        ANSITerminal.(print_string [] (String.concat "" (List.rev
        !current_input_stack)));
        flush_all ();
        draw_update c)
  | Channels ->
      if c.logged_out then Lwt.return ()
      else (
        match c.current_org with
        | None -> failwith "shouldn't happen"
        | Some o ->
          (get_org_info c.current_user o !server_addr) >>=
          fun (_,response_json) ->
          (ANSITerminal.(erase Above);
          ANSITerminal.(move_cursor (-100) 0);
          print_persist ();
          render_org_info o c.current_user response_json;
          ANSITerminal.(print_string [] (String.concat ""
          (List.rev !current_input_stack)));
          flush_all ();
          draw_update c)
      )
  | Messages ->
      if c.logged_out then Lwt.return ()
      else (
        match c.current_org with
        | None -> failwith "shouldn't happen"
        | Some o -> (
          match c.current_channel with
          | None -> failwith "shouldn't happen"
          | Some ch ->
            (get_messages c.current_user ch o c.current_line !server_addr) >>=
            fun (_,response_json) ->
            (ANSITerminal.(erase Above);
            ANSITerminal.(move_cursor (-100) 0);
            render_channel_messages c.message o ch response_json;
            ANSITerminal.(print_string [] (String.concat "" (List.rev
            !current_input_stack)));
            flush_all ();
            draw_update c)
        )
      )
  )

let _ =
  let in_channel = open_in "main_config.txt" in
  let text = ref "" in
  try
    return (while true do
      let line = input_line in_channel in
      text := !text ^ line
    done)
  with
  | End_of_file -> begin
    close_in in_channel;
    (server_addr := !text |> Yojson.Basic.from_string |>
      Yojson.Basic.Util.member "server_hostname" |> 
      Yojson.Basic.Util.to_string);
    ANSITerminal.resize 80 34;
  	print_string
  "                         MMMMMMM                     MMMMMMMMMMMMMM
                        MMMMMMMMMMMM                MMMMMMMMMM MMMMMMMM
                      MMMMMMMMMMMMMMMM                MMMMMMMMMMMMMMMMM
                 MMMMMMMMMMMMMMMMMMMMMM              MMMMMMMMMMMMM   MM
              MMMMMMMMMMMMMMMMMMMMMMMMMMM            MMMMMMMMMMM
            MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM        MMMMMMMMMMMM
          MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM    MMMMMMMMMMMMM
          MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
         MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
         MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
         MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
        MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
       MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
      MMMMMMMM  MMMMMMMM  MMMMMMMMMMMMMMMMMMMM
     MMMMM  M   MMMMMMM       MNMMMMMMMMMMMMMM
   MMMMM  MMMM  MMMMMM          MMMMM  MMMMMM
  MMMMMM  MMM  MMMMMM           MMMMM   MMMMM
  MMMMM     M  MMMMM            MMMM     MMMM
  MMMM        MMMMM           MMMMMM      MMMMM
   MMM       MMMMMMM          NMMMMM      MMMMM
   MM         MMMM             MMMM         MMM
  MMMM         MMMM           MMMM           MM
   MMM          MMM           MMM            MMM
   MMMM         MMMM         MMM              MMM
   MMMMM         MMM        MMMM               MMM
     MMMMMM      MMMM        MMMM              MMMMMM
        MMM       MMMMM       MMMM              MMMMMM
                    MMMMM                        MMMMM
                      MMMMM";
    ANSITerminal.(print_string [green]
      "\n\nHello! and Welcome to Camel Talk.\n");
    ANSITerminal.(print_string [Bold; blue]
    	"Would you like to log in or register?");
    ANSITerminal.(print_string [Bold; blue]
    	"\nType \"login\" to Log in, or \"register\" to Register\n");
    ANSITerminal.(print_string [] "> ");
    (let termio = Unix.tcgetattr Unix.stdin in
    Unix.tcsetattr Unix.stdin Unix.TCSADRAIN {termio with Unix.c_icanon = true;
    Unix.c_echo = true;});
    if (read_line ()) = "login" then login () else register ()
  end
