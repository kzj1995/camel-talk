(** 
 * Values of type command represent user commands to the REPL. Examples of how
 * commands are represented:
 *  - CIllegal represents an unparseable message
 *  - CSimpleMessage "Hello" represents the message "Hello"
 *  - CReminderMessage ("Walk the camel", 500) represents a command to remind
 *    the user to walk the camel at 500 seconds after 1970.
 *  - CPollMessage ("What's your favorite color?", ["Blue", "Red"]) represents
 *    a poll titled "What's your favorite color?" and with options "Blue" and
 *    "Red"
 *  - CCreateOrg "CS3110" represents a request to create an organization called
 *    "CS3110"
 *  - CDeleteOrg "CS3110" represents a request to delete an organization called
 *    "CS3110"
 *  - CCreateChannel and CDeleteChannel behave similarly to CCreateOrg and
 *    CDeleteOrg
 *  - CSwitchOrg "CS2110" represents a request to switch to the organization
 *    called "CS2110"
 *  - CSwitchChannel behaves similarly to CSwitchOrg.
 *)
type command =
  | CIllegal
  | CSimpleMessage of string
  | CReminderMessage of string * int
  | CPollMessage of string * string list
  | CCreateOrg of string
  | CDeleteOrg of string
  | CCreateChannel of string
  | CDeleteChannel of string
  | CSwitchOrg of string
  | CSwitchChannel of string

(** text_to_message [cmd] is a command representing that message. *)
val text_to_message : string -> command