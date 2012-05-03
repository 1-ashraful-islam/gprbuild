------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                             G P R C O N F I G                            --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--                   Copyright (C) 2006-2011, AdaCore                       --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 2,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT;  see file COPYING.  If not, write --
-- to  the  Free Software Foundation,  51  Franklin  Street,  Fifth  Floor, --
-- Boston, MA 02110-1301, USA.                                              --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  This unit is responsible for parsing the gprconfig knowledge base

with Ada.Containers.Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Doubly_Linked_Lists;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with GNAT.Regpat;
with Namet;

package GprConfig.Knowledge is

   Generate_Error : exception;
   --  To be raised when an error occurs during generation of config files

   --------------------
   -- Knowledge base --
   --------------------
   --  The following types and subprograms manipulate the knowldge base. This
   --  base is a set of XML files that describe how to find compilers that are
   --  installed on the system and that match specific criterias.

   type Knowledge_Base is private;

   function Default_Knowledge_Base_Directory return String;
   --  Return the default location of the knowledge database. This is based on
   --  the installation directory of the executable.

   procedure Parse_Knowledge_Base
     (Base                : in out Knowledge_Base;
      Directory           : String;
      Parse_Compiler_Info : Boolean := True);
   --  Parse info from the knowledge base, and store it in memory.
   --  Only information relevant to the current host is parsed.
   --  If Parse_Compiler_Info is False, then only the information about
   --  target sets is parsed.
   --  This procedure will raise Invalid_Knowledge_Base if the base contains
   --  incorrect data.

   Invalid_Knowledge_Base : exception;
   --  To be raised when an error occurred while parsing the knowledge base

   -----------------
   -- Target sets --
   -----------------
   --  One of the information pieces contain in the database is a way to
   --  normalize target names, since various names are used in different
   --  contexts thus making it harder to write project files depending on the
   --  target.

   type Targets_Set_Id is private;
   --  Identify a target aliases set

   All_Target_Sets     : constant Targets_Set_Id;
   --  Matches all target sets

   Unknown_Targets_Set : constant Targets_Set_Id;
   --  Special target set when a target is not known

   function Query_Targets_Set
     (Base   : Knowledge_Base;
      Target : String) return Targets_Set_Id;
   --  Get the target alias set id for a target, or Unknown_Targets_Set if
   --  no such target is in the base.

   procedure Get_Targets_Set
     (Base   : in out Knowledge_Base;
      Target : String;
      Id     : out Targets_Set_Id);
   --  Get the target alias set id for a target.  If not already in the base,
   --  add it.

   function Normalized_Target
     (Base : Knowledge_Base;
      Set  : Targets_Set_Id) return String;
   --  Return the normalized name for a target set

   ---------------
   -- Compilers --
   ---------------
   --  Most of the information in the database relates to compilers. However,
   --  you do not have direct access to the generic description that explains
   --  how to find compilers on the PATH and how to compute their attributes
   --  (version, runtimes,...) Instead, this package gives you access to the
   --  list of compilers that were found. The package ensures that all
   --  information is only computed at most once, to save on system calls and
   --  provide better performance.

   type Compiler is private;
   type Compiler_Access is access all Compiler;

   function Runtime_Dir_Of (Comp : Compiler_Access) return Namet.Name_Id;
   --  Return the name of the runtime directory for the compiler. Returns
   --  No_Name if Comp is null.

   package Compiler_Lists
      is new Ada.Containers.Indefinite_Doubly_Linked_Lists (Compiler_Access);
   --  A list of compilers

   function Is_Selected (Comp : Compiler) return Boolean;
   function Target      (Comp : Compiler) return Namet.Name_Id;

   procedure Set_Selection
     (Compilers : in out Compiler_Lists.List;
      Cursor    : Compiler_Lists.Cursor;
      Selected  : Boolean);
   procedure Set_Selection
     (Comp     : in out Compiler;
      Selected : Boolean);
   --  Toggle the selection status of a compiler in the list.
   --  This does not check that the selection is consistent though (use
   --  Is_Supported_Config to do this test)

   function To_String
     (Base            : Knowledge_Base;
      Comp            : Compiler;
      As_Config_Arg   : Boolean;
      Show_Target     : Boolean := False;
      Rank_In_List    : Integer := -1;
      Parser_Friendly : Boolean := False) return String;
   --  Return a string representing the compiler. It is either the --config
   --  argument (if As_Config_Arg is true) or the string to use in the
   --  interactive menu otherwise.
   --  If Rank_In_List is specified, it is written at the beginning of the
   --  line.
   --  If Parser_Friendly is set, then the list is displayed in a way that can
   --  be easily parsed automatically

   function To_String
     (Base            : Knowledge_Base;
      Compilers       : Compiler_Lists.List;
      Selected_Only   : Boolean;
      Show_Target     : Boolean := False;
      Parser_Friendly : Boolean := False) return String;
   --  Return the list of compilers.
   --  Unselectable compilers are hidden. If Selected_Only is true, then only
   --  compilers that are currently selected are displayed.
   --  If Parser_Friendly is set, then the list is displayed in a way that can
   --  be easily parsed automatically

   function Display_Before (Comp1, Comp2 : Compiler_Access) return Boolean;
   --  Whether Comp1 should be displayed before Comp2 when displaying lists of
   --  compilers. This ensures that similar languages are grouped, among othe
   --  things.

   procedure Filter_Compilers_List
     (Base           : Knowledge_Base;
      Compilers      : in out Compiler_Lists.List;
      For_Target_Set : Targets_Set_Id);
   --  Based on the currently selected compilers, check which other compilers
   --  can or cannot be selected by the user.
   --  This is not the case if the resulting selection in Compilers is not a
   --  supported config (multiple compilers for the same language, set of
   --  compilers explicitly marked as unsupported in the knowledge base,...).

   ------------------
   -- Command line --
   ------------------
   --  This package provides support for manipulating the --config command line
   --  parameters. The intent is that they have the same form in all the tools
   --  that support it. The information provides to --config might be partial
   --  only, and this package provides support for completing it automatically
   --  based on the knowledge base.

   procedure Parse_Config_Parameter
     (Base              : Knowledge_Base;
      Config            : String;
      Compiler          : out Compiler_Access;
      Requires_Compiler : out Boolean);
   --  Parse the --config parameter, and store the (partial) information
   --  found in Compiler.
   --  When a switch matches a language that requires no compiler,
   --  Requires_Compiler is set to False.
   --  Raises Invalid_Config if Config is invalid

   Invalid_Config : exception;
   --  Raised when the user has specified an invalid --config switch

   procedure Complete_Command_Line_Compilers
     (Base      : in out Knowledge_Base;
      On_Target : Targets_Set_Id;
      Filters   : Compiler_Lists.List;
      Compilers : in out Compiler_Lists.List);
   --  In batch mode, the --config parameters indicate what compilers should be
   --  selected. Each of these switch selects the first matching compiler
   --  available, and all --config switch must match a compiler.
   --  The information provided by the user does not have to be complete, and
   --  this procedure completes all missing information like version, runtime,
   --  and so on.
   --  In gprconfig, it should only be called in batch mode, since otherwise
   --  --config only acts as a filter for the compilers that are found through
   --  the knowledge base.
   --  Filters is the list specified by the user as --config, and contains
   --  potentially partial information for each compiler. On output, Compilers
   --  is completed with the full information for all compilers in Filters. If
   --  at least one of the compilers in Filters cannot be found, Invalid_Config
   --  is raised.

   function Extra_Dirs_From_Filters
     (Filters : Compiler_Lists.List) return String;
   --  Compute the list of directories that should be prepended to the PATH
   --  when searching for compilers. These are all the directories that the
   --  user has explicitly specified in his filters (aka --config)

   -----------------------------
   -- knowledge base contents --
   -----------------------------

   function Hash_Case_Insensitive
     (Name : Namet.Name_Id) return Ada.Containers.Hash_Type;
   package Variables_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Namet.Name_Id,
      Element_Type    => Namet.Name_Id,
      Hash            => Hash_Case_Insensitive,
      Equivalent_Keys => Namet."=",
      "="             => Namet."=");

   No_Compiler : constant Compiler;
   --  Describes one of the compilers found on the PATH.
   --  Path is the directory that contains the compiler executable.
   --  Path_Order is used for sorting in the interactive menu: it indicates the
   --  index in $PATH of the directory, so that we can show first the compilers
   --  that are first in path.
   --  Any of these compilers can be selected by the user as part of a config.
   --  However, to prevent incompatibilities, a compiler can be marked as not
   --  selectable. This will be re-evaluated based on the current selection.
   --  Complete is set to True if all the information about the compiler was
   --  computed. It is set to False if the compiler was specified through a
   --  command line argument --config, and part of the info needs to be
   --  computed.
   --  Index_In_List is used for the interactive menu, and is initialized
   --  automatically.

   type Compiler_Iterator is abstract tagged null record;
   --  An iterator that searches for all known compilers in a list of
   --  directories. Whenever a new compiler is found, the Callback primitive
   --  operation is called.

   procedure Callback
     (Iterator       : in out Compiler_Iterator;
      Base           : in out Knowledge_Base;
      Comp           : Compiler;
      From_Extra_Dir : Boolean;
      Continue       : out Boolean) is abstract;
   --  Called whenever a new compiler is discovered.
   --  It might be discovered either in a path added through a --config
   --  parameter (in which case From_Extra_Dir is True), or in a path specified
   --  in the environment variable $PATH (in which case it is False). If the
   --  directory is both in Extra_Dirs and in $PATH, From_Extra_Dir is set to
   --  False.
   --  On exit, Continue should be set to False if there is no need to discover
   --  further compilers (however there will be no possibility to restart the
   --  search at the same point later on).

   procedure Foreach_Compiler_In_Path
     (Iterator   : in out Compiler_Iterator;
      Base       : in out Knowledge_Base;
      On_Target  : Targets_Set_Id;
      Extra_Dirs : String := "");
   --  Find all compilers in "Extra_Dirs & $PATH".
   --  Extra_Dirs should typically be the list of directories found in
   --  --config command line arguments.
   --  The only filtering done is the target, for optimization purposes (no
   --  need to computed all info about the compiler if we know it will not be
   --  uses anyway).

   procedure Known_Compiler_Names
     (Base : Knowledge_Base;
      List : out Ada.Strings.Unbounded.Unbounded_String);
   --  Set List to the comma-separated list of known compilers

   procedure Generate_Configuration
     (Base        : Knowledge_Base;
      Compilers   : Compiler_Lists.List;
      Output_File : String;
      Target      : String);
   --  Generate the configuration file for the list of selected compilers

   package String_Lists is
     new Ada.Containers.Indefinite_Doubly_Linked_Lists (String);

   procedure Put_Verbose (Str : String; Indent_Delta : Integer := 0);
   --  Print Str if verbose mode is activated.
   --  Indent_Delta will increase the current indentation level for all further
   --  traces, which is used to highlight nested calls. Only the sign of
   --  Indent_Delta is taken into account.
   --  Nothing is printed if Str is the empty string, only the indentation is
   --  changed

   function Filter_Match
     (Base : Knowledge_Base;
      Comp   : Compiler;
      Filter : Compiler) return Boolean;
   --  Returns True if Comp match Filter (the latter corresponds to a --config
   --  command line argument).

private
   type Targets_Set_Id is range -1 .. Natural'Last;

   All_Target_Sets     : constant Targets_Set_Id := -1;
   Unknown_Targets_Set : constant Targets_Set_Id := 0;

   type Compiler is record
      Name        : Namet.Name_Id := Namet.No_Name;
      --  The name of the compiler, as specified in the <name> node of the
      --  knowledge base. If Compiler represents a filter as defined on through
      --  --config switch, then name can also be the base name of the
      --  executable we are looking for. In such a case, it never includes the
      --  exec suffix (.exe on Windows)

      Executable  : Namet.Name_Id := Namet.No_Name;
      Target      : Namet.Name_Id := Namet.No_Name;
      Targets_Set : Targets_Set_Id;
      Path        : Namet.Name_Id := Namet.No_Name;

      Base_Name   : Namet.Name_Id := Namet.No_Name;
      --  Base name of the executable. This does not include the exec suffix

      Version     : Namet.Name_Id := Namet.No_Name;
      Variables   : Variables_Maps.Map;
      Prefix      : Namet.Name_Id := Namet.No_Name;
      Runtime     : Namet.Name_Id := Namet.No_Name;
      Runtime_Dir : Namet.Name_Id := Namet.No_Name;
      Path_Order  : Integer;

      Language_Case : Namet.Name_Id := Namet.No_Name;
      --  The supported language, with the casing read from the compiler. This
      --  is for display purposes only

      Language_LC : Namet.Name_Id := Namet.No_Name;
      --  The supported language, always lower case

      Selectable   : Boolean := True;
      Selected     : Boolean := False;
      Complete     : Boolean := True;
   end record;

   No_Compiler : constant Compiler :=
                   (Name          => Namet.No_Name,
                    Target        => Namet.No_Name,
                    Targets_Set   => Unknown_Targets_Set,
                    Executable    => Namet.No_Name,
                    Base_Name     => Namet.No_Name,
                    Path          => Namet.No_Name,
                    Variables     => Variables_Maps.Empty_Map,
                    Version       => Namet.No_Name,
                    Prefix        => Namet.No_Name,
                    Runtime       => Namet.No_Name,
                    Runtime_Dir   => Namet.No_Name,
                    Language_Case => Namet.No_Name,
                    Language_LC   => Namet.No_Name,
                    Selectable    => False,
                    Selected      => False,
                    Complete      => True,
                    Path_Order    => 0);

   type Pattern_Matcher_Access is access all GNAT.Regpat.Pattern_Matcher;

   type External_Value_Type is (Value_Constant,
                                Value_Shell,
                                Value_Directory,
                                Value_Grep,
                                Value_Filter,
                                Value_Must_Match,
                                Value_Variable,
                                Value_Done);
   type External_Value_Node
     (Typ : External_Value_Type := Value_Constant) is
      record
         case Typ is
            when Value_Constant  =>
               Value           : Namet.Name_Id;
            when Value_Shell     =>
               Command         : Namet.Name_Id;
            when Value_Directory  =>
               Directory       : Namet.Name_Id;
               Directory_Group : Integer;
               Dir_If_Match    : Namet.Name_Id;
               Contents        : Pattern_Matcher_Access;
            when Value_Grep       =>
               Regexp_Re       : Pattern_Matcher_Access;
               Group           : Natural;
            when Value_Filter     =>
               Filter          : Namet.Name_Id;
            when Value_Must_Match =>
               Must_Match      : Namet.Name_Id;
            when Value_Variable =>
               Var_Name        : Namet.Name_Id;
            when Value_Done =>
               null;
         end case;
      end record;

   package External_Value_Nodes is
     new Ada.Containers.Doubly_Linked_Lists (External_Value_Node);

   subtype External_Value is External_Value_Nodes.List;

   Null_External_Value : constant External_Value :=
                           External_Value_Nodes.Empty_List;

   type Compiler_Description is record
      Name             : Namet.Name_Id := Namet.No_Name;
      Executable       : Namet.Name_Id := Namet.No_Name;
      Executable_Re    : Pattern_Matcher_Access;
      Prefix_Index     : Integer := -1;
      Target           : External_Value;
      Version          : External_Value;
      Variables        : External_Value;
      Languages        : External_Value;
      Runtimes         : External_Value;
      Default_Runtimes : String_Lists.List;
   end record;
   --  Executable_Re is only set if the name of the <executable> must be
   --  taken as a regular expression.

   package Compiler_Description_Maps is new
     Ada.Containers.Indefinite_Hashed_Maps
       (Namet.Name_Id, Compiler_Description,
        Hash_Case_Insensitive, Namet."=");

   type Compiler_Filter is record
      Name        : Namet.Name_Id;
      Version     : Namet.Name_Id;
      Version_Re  : Pattern_Matcher_Access;
      Runtime     : Namet.Name_Id;
      Runtime_Re  : Pattern_Matcher_Access;
      Language_LC : Namet.Name_Id;
   end record;
   --  Representation for a <compiler> node (in <configuration>)

   package Compiler_Filter_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Compiler_Filter);

   type Compilers_Filter is record
      Compiler : Compiler_Filter_Lists.List;
      Negate   : Boolean := False;
   end record;

   No_Compilers_Filter : constant Compilers_Filter :=
                           (Compiler => Compiler_Filter_Lists.Empty_List,
                            Negate   => False);
   --  a <compilers> filter, that matches if any of its <compiler> child
   --  matches.

   package Compilers_Filter_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Compilers_Filter);

   type Configuration is record
      Compilers_Filters : Compilers_Filter_Lists.List;
      Targets_Filters   : String_Lists.List;  --  these are regexps
      Negate_Targets    : Boolean  := False;
      Config            : Namet.Name_Id;

      Supported         : Boolean;
      --  Whether the combination of compilers is supported
   end record;

   package Configuration_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Configuration);

   package Target_Lists is new Ada.Containers.Doubly_Linked_Lists
     (Pattern_Matcher_Access);

   type Target_Set_Description is record
      Name     : Namet.Name_Id;
      Patterns : Target_Lists.List;
   end record;

   subtype Known_Targets_Set_Id
     is Targets_Set_Id range 1 .. Targets_Set_Id'Last;
   --  Known targets set.  They are in the base

   package Targets_Set_Vectors is new Ada.Containers.Vectors
     (Known_Targets_Set_Id, Target_Set_Description, "=");

   type Knowledge_Base is record
      Compilers               : Compiler_Description_Maps.Map;
      No_Compilers            : String_Lists.List;
      Check_Executable_Regexp : Boolean := False;
      Configurations          : Configuration_Lists.List;
      Targets_Sets            : Targets_Set_Vectors.Vector;
   end record;
   --  Check_Executable_Regexp is set to True if at least some of the
   --  executable names are specified as regular expressions. In such a case,
   --  a slightly slower algorithm is used to search for compilers.
   --  No_Compilers is the list of languages that require no compiler, and thus
   --  should not be searched on the PATH.

end GprConfig.Knowledge;
