------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                            G P R _ U T I L                               --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--            Copyright (C) 2007-2011, Free Software Foundation, Inc.       --
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

--  This package contains constants, variable and subprograms used by gprbuild
--  and gprclean.

with GNAT.OS_Lib; use GNAT.OS_Lib;

with ALI;
with Namet;    use Namet;
with Prj;      use Prj;
with Prj.Tree; use Prj.Tree;

package Gpr_Util is

   Partial_Prefix : constant String := "p__";

   Begin_Info : constant String := "--  BEGIN Object file/option list";
   End_Info   : constant String := "--  END Object file/option list   ";

   Project_Node_Tree : constant Project_Node_Tree_Ref :=
     new Project_Node_Tree_Data;
   --  This is also used to hold project path and scenario variables

   Root_Environment : Prj.Tree.Environment;
   --  The environment coming from environment variables and command line
   --  switches. When we do not have an aggregate project, this is used for
   --  parsing the project tree. When we have an aggregate project, this is
   --  used to parse the aggregate project; the latter then generates another
   --  environment (with additional external values and project path) to parse
   --  the aggregated projects.

   Success : Boolean := False;

   --  Config project

   Config_Project_Option : constant String := "--config=";

   Autoconf_Project_Option : constant String := "--autoconf=";

   Target_Project_Option : constant String := "--target=";

   No_Name_Map_File_Option : constant String := "--map-file-option";

   Named_Map_File_Option   : constant String := No_Name_Map_File_Option & '=';

   Config_Path : String_Access := null;

   Target_Name : String_Access := null;

   Config_Project_File_Name   : String_Access := null;
   Configuration_Project_Path : String_Access := null;
   --  Base name and full path to the configuration project file

   Autoconfiguration : Boolean := True;
   --  Whether we are using an automatically config (from gprconfig)

   Autoconf_Specified : Boolean := False;
   --  Whether the user specified --autoconf on the gprbuild command line

   Delete_Autoconf_File : Boolean := False;
   --  This variable is used by gprclean to decide if the config project file
   --  should be cleaned. It is set to True when the config project file is
   --  automatically generated or --autoconf= is used.

   --  Default project

   Default_Project_File_Name : constant String := "default.gpr";

   --  User projects

   Project_File_Name          : String_Access := null;
   --  The name of the project file specified with switch -P

   Main_Project : Project_Id;
   --  The project id of the main project

   RTS_Option : constant String := "--RTS=";

   RTS_Language_Option : constant String := "--RTS:";

   Db_Directory_Expected : Boolean := False;
   --  True when last switch was --db

   Load_Standard_Base : Boolean := True;
   --  False when switch --db- is used

   --  Local subprograms

   function Binder_Exchange_File_Name
     (Main_Base_Name : File_Name_Type; Prefix : Name_Id)
      return String_Access;
   --  Returns the name of the binder exchange file corresponding to an
   --  object file and a language.
   --  Main_Base_Name must have no extension specified

   procedure Create_Response_File
     (Format            : Response_File_Format;
      Objects           : String_List;
      Other_Arguments   : String_List;
      Resp_File_Options : String_List;
      Name_1            : out Path_Name_Type;
      Name_2            : out Path_Name_Type);
   --  Create a temporary file as a response file that contains either the list
   --  of Objects in the correct Format, or for Format GCC the list of all
   --  arguments. It is the responsibility of the caller to delete this
   --  temporary file if needed.

   ----------
   -- Misc --
   ----------

   procedure Find_Binding_Languages
     (Tree         : Project_Tree_Ref;
      Root_Project : Project_Id);
   --  Check if in the project tree there are sources of languages that have
   --  a binder driver.
   --  Populates Tree's appdata (Binding and There_Are_Binder_Drivers).
   --  Nothing is done if the binding languages were already searched for
   --  this Tree.
   --  This also performs the check for aggregated project trees.

   function Get_Compiler_Driver_Path
     (Project_Tree : Project_Tree_Ref;
      Lang         : Language_Ptr) return String_Access;
   --  Get, from the config, the path of the compiler driver. This is first
   --  looked for on the PATH if needed.
   --  Returns "null" if no compiler driver was specified for the language, and
   --  exit with an error if one was specified but not found.

   procedure Look_For_Default_Project;
   --  Check if default.gpr exists in the current directory. If it does, use
   --  it. Otherwise, if there is only one file ending with .gpr, use it.

   function Partial_Name
     (Lib_Name      : String;
      Number        : Natural;
      Object_Suffix : String) return String;
   --  Returns the name of an object file created by the partial linker

   function Shared_Libgcc_Dir (Run_Time_Dir : String) return String;
   --  Returns the directory of the shared version of libgcc, if it can be
   --  found, otherwise returns an empty string.

   package Knowledge is
      function Normalized_Hostname return String;
      --  Return the normalized name of the host on which gprbuild is running.
      --  The knowledge base must have been parsed first.

      procedure Parse_Knowledge_Base
        (Project_Tree : Project_Tree_Ref;
         Directory : String := "");

   end Knowledge;

   procedure Need_To_Compile
     (Source         : Prj.Source_Id;
      Tree           : Prj.Project_Tree_Ref;
      In_Project     : Prj.Project_Id;
      Must_Compile   : out Boolean;
      The_ALI        : out ALI.ALI_Id;
      Object_Check   : Boolean;
      Always_Compile : Boolean);
   --  Check if a source need to be compiled.
   --  A source need to be compiled if:
   --    - Force_Compilations is True
   --    - No object file generated for the language
   --    - Object file does not exist
   --    - Dependency file does not exist
   --    - Switches file does not exist
   --    - Either of these 3 files are older than the source or any source it
   --      depends on.
   --  If an ALI file had to be parsed, it is returned as The_ALI, so that the
   --  caller does not need to parse it again.
   --
   --  Object_Check should be False when switch --no-object-check is used. When
   --  True, presence of the object file and its time stamp are checked to
   --  decide if a file needs to be compiled.
   --
   --  Tree is the project tree in which Source is found (or the root tree when
   --  not using aggregate projects).
   --
   --  Always_Compile should be True when gprbuid is called with -f -u and at
   --  least one source on the command line.

end Gpr_Util;
