------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                               G P R L I B                                --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--            Copyright (C) 2006-2007, Free Software Foundation, Inc.       --
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

--  gprlib is called by gprmake to build the library for a library project
--  file. gprlib gets it parameters from a text file and give back results
--  through the same text file.

with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;       use Ada.Strings.Fixed;
with Ada.Text_IO;             use Ada.Text_IO;
with Ada.Command_Line;        use Ada.Command_Line;

with ALI;
with Csets;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;

with Gprexch;   use Gprexch;
with Hostparm;
with Makeutl;   use Makeutl;
with Namet;     use Namet;
with Opt;       use Opt;
with Osint;
with Prj;
with Snames;
with Switch;    use Switch;
with Table;
with Targparm;
with Types;     use Types;

procedure Gprlib is

   Gcc_Name : constant String := "gcc";

   Preserve : Attribute := Time_Stamps;
   --  Used by Copy_ALI_Files. Changed to None for OpenVMS, because
   --  Copy_Attributes always fails on VMS.

   Object_Suffix : constant String := Get_Target_Object_Suffix.all;
   --  The suffix of object files on this platform

   --  Switches used when spawning processes

   No_Main_String : constant String := "-n";
   No_Main        : constant String_Access := new String'(No_Main_String);

   Output_Switch_String : constant String := "-o";
   Output_Switch        : constant String_Access :=
                            new String'(Output_Switch_String);

   Compile_Switch_String : constant String := "-c";
   Compile_Switch        : constant String_Access :=
                             new String'(Compile_Switch_String);

   Auto_Initialize_String : constant String := "-a";
   Auto_Initialize        : constant String_Access :=
                              new String'(Auto_Initialize_String);

   IO_File : File_Type;
   --  The file to get the inputs and to put the results

   Line : String (1 .. 1_000);
   Last : Natural;

   Exchange_File_Name : String_Access;
   --  Name of the exchange file

   S_Osinte_Ads : File_Name_Type := No_File;
   --  Name_Id for "s-osinte.ads"

   S_Dec_Ads : File_Name_Type := No_File;
   --  Name_Id for "dec.ads"

   G_Trasym_Ads : File_Name_Type := No_File;
   --  Name_Id for "g-trasym.ads"

   Current_Section : Library_Section := No_Library_Section;
   --  The current section when reading the exchange file

   Standalone : Boolean := False;
   --  True when building a stand-alone library

   Library_Path_Name : String_Access;
   --  Path name of the library file

   package Object_Files is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Object_Files");
   --  A table to store the object files of the library

   Last_Object_File_Index : Natural := 0;
   --  Index of the last object file in the Object_Files table. When building
   --  a Stand Alone Library, the binder generated object file will be added
   --  in the Object_Files table.

   package Options_Table is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Options_Table");
   --  A table to store the options from the exchange file

   package Imported_Library_Directories is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Imported_Librar_Directories");
   --  A table to store the directories of the imported libraries

   package Imported_Library_Names is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Imported_Librar_Names");
   --  A table to store the names of the imported libraries

   package ALIs is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 50,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Alis");
   --  A table to store all of the ALI files

   package Interface_ALIs is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 50,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Interface_Alis");
   --  A table to store the ALI files of the interfaces of an SAL

   package Binding_Options_Table is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 5,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Binding_Options_Table");
   --  A table to store the binding options

   package Library_Options_Table is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 5,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Library_Options_Table");
   --  A table to store the library options

   package Object_Directories is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 2,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Object_Directories");
   --  A table to store the object directories of the project and of all
   --  the projects it extends.

   package Sources is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 2,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Sources");

   Auto_Init : Boolean := False;
   --  True when a SAL is auto initializable

   Static : Boolean := False;
   --  True if the library is an archive

   Archive_Builder : String_Access := null;
   --  Name of the archive builder

   AB_Options     : String_List_Access := new String_List (1 .. 10);
   Last_AB_Option : Natural := 0;
   --  Options of the archive builder

   Archive_Indexer : String_Access := null;
   --  Name of the archive indexer

   AI_Options     : String_List_Access := new String_List (1 .. 10);
   Last_AI_Option : Natural := 0;
   --  Options of the archive indexer

   Partial_Linker : String_Access := null;
   --  Name of the library partial linker

   PL_Options     : String_List_Access := new String_List (1 .. 10);
   Last_PL_Option : Natural := 0;
   --  Options of the library partial linker

   Partial_Linker_Path : String_Access;
   --  The path to the partial linker driver

   Archive_Suffix : String_Access := new String'(".a");

   Bind_Options     : String_List_Access := new String_List (1 .. 10);
   Last_Bind_Option : Natural := 0;

   Success : Boolean;

   Relocatable : Boolean := False;

   Library_Name : String_Access := null;

   Library_Directory : String_Access := null;

   Library_Dependency_Directory : String_Access := null;

   Library_Version : String_Access := new String'("");

   Symbolic_Link_Supported  : Boolean := False;

   Major_Minor_Id_Supported : Boolean := False;

   PIC_Option : String_Access := null;

   package Library_Version_Options is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 2,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Library_Version_Options");

   Shared_Lib_Prefix : String_Access := new String'("lib");

   Shared_Lib_Suffix : String_Access := new String'(".so");

   package Shared_Lib_Minimum_Options is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 2,
      Table_Increment      => 100,
      Table_Name           => "Gprlib.Shared_Lib_Minimum_Options");

   Copy_Source_Directory : String_Access := null;

   Driver_Name : Name_Id := No_Name;

   Gnatbind_Name : constant String_Access := Osint.Program_Name ("gnatbind");

   Gnatbind_Path : String_Access;

   GNAT_Runtime_Dir : String_Access := null;

   Compiler_Name : constant String_Access := Osint.Program_Name ("gcc");

   Compiler_Path : String_Access;

   Libgnarl_Needed : Boolean := False;
   --  Set to True if library needs to be linked with libgnarl

   Libdecgnat_Needed : Boolean := False;
   --  On OpenVMS, set to True if library needs to be linked with libdecgnat

   Gtrasymobj_Needed : Boolean := False;
   --  On OpenVMS, set to True if library needs to be linked with
   --  g-trasym.obj.

   Path_Option : String_Access := null;

   Rpath : String_Access := null;
   --  Allocated only if Path Option is supported

   Rpath_Last : Natural := 0;
   --  Index of last valid character of Rpath

   Initial_Rpath_Length : constant := 200;
   --  Initial size of Rpath, when first allocated

   Lgnat : String_Access := new String'("-lgnat");

   Lgnarl : String_Access := new String'("-lgnarl");

   procedure Add_Rpath (Path : String);
   --  Add a path name to Rpath

   procedure Check_Libs (ALI_File : String);
   --  Set Libgnarl_Needed if the ALI_File indicates that there is a need
   --  to link with -lgnarl (this is the case when there is a dependency
   --  on s-osinte.ads). On OpenVMS, set Libdecgnat_Needed if the ALI file
   --  indicates that there is a need to link with -ldecgnat (this is the
   --  case when there is a dependency on dec.ads), and set
   --  Gtrasymobj_Needed if there is a dependency on g-trasym.ads.

   procedure Copy_ALI_Files;
   --  Copy the ALI files. For not SALs, copy all the ALI files. For SALs,
   --  only copy the interface ALI files, marking them with the special
   --  indicator "SL" on the P line.

   procedure Copy_Sources;
   --  Copy to the Copy_Source_Directory the sources of the interfaces of
   --  a Stand-Alone Library.

   function SALs_Use_Constructors return Boolean;
   --  Indicate if Stand-Alone Libraries are automatically initialized using
   --  the constructor mechanism.

   procedure Build_Shared_Lib;

   procedure Build_Shared_Lib is separate;

   ---------------
   -- Add_Rpath --
   ---------------

   procedure Add_Rpath (Path : String) is

      procedure Double;
      --  Double Rpath size

      ------------
      -- Double --
      ------------

      procedure Double is
         New_Rpath : constant String_Access :=
                       new String (1 .. 2 * Rpath'Length);
      begin
         New_Rpath (1 .. Rpath_Last) := Rpath (1 .. Rpath_Last);
         Free (Rpath);
         Rpath := New_Rpath;
      end Double;

   --  Start of processing for Add_Rpath

   begin
      --  If firt path, allocate initial Rpath

      if Rpath = null then
         Rpath := new String (1 .. Initial_Rpath_Length);
         Rpath_Last := 0;

      else
         --  Otherwise, add a path separator between two path names

         if Rpath_Last = Rpath'Last then
            Double;
         end if;

         Rpath_Last := Rpath_Last + 1;
         Rpath (Rpath_Last) := Path_Separator;
      end if;

      --  Increase Rpath size until it is large enough

      while Rpath_Last + Path'Length > Rpath'Last loop
         Double;
      end loop;

      --  Add the path name

      Rpath (Rpath_Last + 1 .. Rpath_Last + Path'Length) := Path;
      Rpath_Last := Rpath_Last + Path'Length;
   end Add_Rpath;

   ----------------
   -- Check_Libs --
   ----------------

   procedure Check_Libs (ALI_File : String) is
      Lib_File : File_Name_Type;
      Text     : Text_Buffer_Ptr;
      Id       : ALI.ALI_Id;

   begin
      if not Libgnarl_Needed or
        (Targparm.OpenVMS_On_Target and then
           ((not Libdecgnat_Needed) or
              (not Gtrasymobj_Needed)))
      then
         --  Scan the ALI file

         Name_Len := ALI_File'Length;
         Name_Buffer (1 .. Name_Len) := ALI_File;
         Lib_File := Name_Find;
         Text := Osint.Read_Library_Info (Lib_File, True);

         Id  := ALI.Scan_ALI
           (F          => Lib_File,
            T          => Text,
            Ignore_ED  => False,
            Err        => True,
            Read_Lines => "D");
         Free (Text);

         --  Look for s-osinte.ads in the dependencies

         for Index in ALI.ALIs.Table (Id).First_Sdep ..
           ALI.ALIs.Table (Id).Last_Sdep
         loop
            if ALI.Sdep.Table (Index).Sfile = S_Osinte_Ads then
               Libgnarl_Needed := True;

            elsif Targparm.OpenVMS_On_Target then
               if ALI.Sdep.Table (Index).Sfile = S_Dec_Ads then
                  Libdecgnat_Needed := True;

               elsif ALI.Sdep.Table (Index).Sfile = G_Trasym_Ads then
                  Gtrasymobj_Needed := True;
               end if;
            end if;
         end loop;
      end if;
   end Check_Libs;

   --------------------
   -- Copy_ALI_Files --
   --------------------

   procedure Copy_ALI_Files is
      Success      : Boolean := False;
      FD           : File_Descriptor;
      Len          : Integer;
      Actual_Len   : Integer;
      S            : String_Access;
      Curr         : Natural;
      P_Line_Found : Boolean;
      Status       : Boolean;

   begin
      if not Standalone then
         for Index in 1 .. ALIs.Last loop
            declare
               Destination : constant String :=
                               Library_Dependency_Directory.all &
                               Directory_Separator &
                               Base_Name (ALIs.Table (Index).all);
               Disregard : Boolean;
            begin
               if Is_Regular_File (Destination) then
                  Set_Writable (Destination);
                  Delete_File (Destination, Disregard);
               end if;
            end;

            if Verbose_Mode then
               Put ("Copying ");
               Put (ALIs.Table (Index).all);
               Put_Line (" to library dependency directory");
            end if;

            Copy_File
              (ALIs.Table (Index).all,
               Library_Dependency_Directory.all,
               Success,
               Mode => Overwrite,
               Preserve => Preserve);
            exit when not Success;
         end loop;

      else
         for Index in 1 .. Interface_ALIs.Last loop
            declare
               File_Name : String :=
                             Base_Name (Interface_ALIs.Table (Index).all);
               Destination : constant String :=
                               Library_Dependency_Directory.all &
                               Directory_Separator &
                               File_Name;
               Disregard : Boolean;

            begin
               if Is_Regular_File (Destination) then
                  Set_Writable (Destination);
                  Delete_File (Destination, Disregard);
               end if;

               if Verbose_Mode then
                  Put ("Copying ");
                  Put (Interface_ALIs.Table (Index).all);
                  Put_Line (" to library dependency directory");
               end if;

               Osint.Canonical_Case_File_Name (File_Name);

               --  Open the file

               Name_Len := Interface_ALIs.Table (Index)'Length;
               Name_Buffer (1 .. Name_Len) :=
                  Interface_ALIs.Table (Index).all;
               Name_Len := Name_Len + 1;
               Name_Buffer (Name_Len) := ASCII.NUL;

               FD := Open_Read (Name_Buffer'Address, Binary);

               if FD /= Invalid_FD then
                  Len := Integer (File_Length (FD));

                  S := new String (1 .. Len + 3);

                  --  Read the file. Note that the loop is not necessary
                  --  since the whole file is read at once except on VMS.

                  Curr := 1;
                  Actual_Len := Len;

                  while Actual_Len /= 0 loop
                     Actual_Len := Read (FD, S (Curr)'Address, Len);
                     Curr := Curr + Actual_Len;
                  end loop;

                  --  We are done with the input file, so we close it
                  --  (we simply ignore any bad status on the close)

                  Close (FD, Status);

                  P_Line_Found := False;

                  --  Look for the P line. When found, add marker SL at the
                  --  beginning of the P line.

                  for Index in 1 .. Len - 3 loop
                     if (S (Index) = ASCII.LF or else S (Index) = ASCII.CR)
                       and then S (Index + 1) = 'P'
                     then
                        S (Index + 5 .. Len + 3) := S (Index + 2 .. Len);
                        S (Index + 2 .. Index + 4) := " SL";
                        P_Line_Found := True;
                        exit;
                     end if;
                  end loop;

                  if P_Line_Found then

                     --  Create new modified ALI file

                     Name_Len := Library_Dependency_Directory'Length;
                     Name_Buffer (1 .. Name_Len) :=
                       Library_Dependency_Directory.all;
                     Name_Len := Name_Len + 1;
                     Name_Buffer (Name_Len) := Directory_Separator;
                     Name_Buffer
                       (Name_Len + 1 .. Name_Len + File_Name'Length) :=
                       File_Name;
                     Name_Len := Name_Len + File_Name'Length + 1;
                     Name_Buffer (Name_Len) := ASCII.NUL;

                     FD := Create_File (Name_Buffer'Address, Binary);

                     --  Write the modified text and close the newly
                     --  created file.

                     if FD /= Invalid_FD then
                        Actual_Len := Write (FD, S (1)'Address, Len + 3);

                        Close (FD, Status);

                        --  Set Success to True only if the newly
                        --  created file has been correctly written.

                        Success := Status and Actual_Len = Len + 3;

                        if Success then
                           Set_Read_Only
                             (Name_Buffer (1 .. Name_Len - 1));
                        end if;
                     end if;
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Success then
         Osint.Fail ("could not copy ALI files to library directory");
      end if;

   end Copy_ALI_Files;

   ------------------
   -- Copy_Sources --
   ------------------

   procedure Copy_Sources is
      Text     : Text_Buffer_Ptr;
      The_ALI  : ALI.ALI_Id;
      Lib_File : File_Name_Type;

      First_Unit  : ALI.Unit_Id;
      Second_Unit : ALI.Unit_Id;

      Copy_Subunits : Boolean := False;

      use ALI;

      procedure Copy (File_Name : File_Name_Type);
      --  Copy one source of the project to the copy source directory

      ----------
      -- Copy --
      ----------

      procedure Copy (File_Name : File_Name_Type) is
         Success : Boolean := False;

         Fname   : constant String := Get_Name_String (File_Name);

      begin
         for Index in 1 .. Sources.Last loop
            if Base_Name (Sources.Table (Index).all) = Fname then

               Copy_File
                 (Sources.Table (Index).all,
                  Copy_Source_Directory.all,
                  Success,
                  Mode     => Overwrite,
                  Preserve => Preserve);
               exit;
            end if;
         end loop;
      end Copy;

   begin
      for Index in 1 .. Interface_ALIs.Last loop

         --  First, load the ALI file

         Name_Len := 0;
         Add_Str_To_Name_Buffer (Interface_ALIs.Table (Index).all);
         Lib_File := Name_Find;
         Text := Osint.Read_Library_Info (Lib_File);
         The_ALI :=
           ALI.Scan_ALI (Lib_File, Text, Ignore_ED => False, Err => True);
         Free (Text);

         Second_Unit := ALI.No_Unit_Id;
         First_Unit := ALI.ALIs.Table (The_ALI).First_Unit;
         Copy_Subunits := True;

         --  If there is both a spec and a body, check if they are both needed

         if ALI.Units.Table (First_Unit).Utype = ALI.Is_Body then
            Second_Unit := ALI.ALIs.Table (The_ALI).Last_Unit;

            --  If the body is not needed, then reset First_Unit

            if not ALI.Units.Table (Second_Unit).Body_Needed_For_SAL then
               First_Unit := ALI.No_Unit_Id;
               Copy_Subunits := False;
            end if;

         elsif ALI.Units.Table (First_Unit).Utype = ALI.Is_Spec_Only then
            Copy_Subunits := False;
         end if;

         --  Copy the file(s) that need to be copied

         if First_Unit /= No_Unit_Id then
            Copy (File_Name => ALI.Units.Table (First_Unit).Sfile);
         end if;

         if Second_Unit /= No_Unit_Id then
            Copy (File_Name => ALI.Units.Table (Second_Unit).Sfile);
         end if;

         --  Copy all the separates, if any

         if Copy_Subunits then
            for Dep in ALI.ALIs.Table (The_ALI).First_Sdep ..
              ALI.ALIs.Table (The_ALI).Last_Sdep
            loop
               if ALI.Sdep.Table (Dep).Subunit_Name /= No_Name then
                  Copy (File_Name => Sdep.Table (Dep).Sfile);
               end if;
            end loop;
         end if;
      end loop;
   end Copy_Sources;

   ---------------------------
   -- SALs_Use_Constructors --
   ---------------------------

   function SALs_Use_Constructors return Boolean is
      function C_SALs_Init_Using_Constructors return Integer;
      pragma Import (C, C_SALs_Init_Using_Constructors,
                     "__gnat_sals_init_using_constructors");
   begin
      return C_SALs_Init_Using_Constructors /= 0;
   end SALs_Use_Constructors;

begin
   --  Initialize some packages

   Csets.Initialize;
   Namet.Initialize;
   Snames.Initialize;

   --  Copy_Attributes always fails on VMS

   if Hostparm.OpenVMS then
      Preserve := None;
   end if;
   if Argument_Count /= 1 then
      Put_Line ("usage: gprlib <input file>");

      if Argument_Count /= 0 then
         Osint.Fail ("incorrect invocation");
      end if;

      return;
   end if;

   Exchange_File_Name := new String'(Argument (1));

   --  DEBUG: save a copy of the exchange file

   if Getenv ("GPRLIB_DEBUG").all = "TRUE" then
      Copy_File
        (Exchange_File_Name.all,
         Exchange_File_Name.all & "__saved",
         Success);
   end if;

   begin
      Open (IO_File, In_File, Exchange_File_Name.all);
   exception
      when others =>
         Osint.Fail ("could not read ", Exchange_File_Name.all);
   end;

   while not End_Of_File (IO_File) loop
      Get_Line (IO_File, Line, Last);

      if Last > 0 then
         if Line (1) = '[' then
            Current_Section := Get_Library_Section (Line (1 .. Last));

            case Current_Section is
               when No_Library_Section =>
                  Osint.Fail ("unknown section: ", Line (1 .. Last));

               when Quiet =>
                  Quiet_Output := True;
                  Verbose_Mode := False;

               when Verbose =>
                  Quiet_Output := False;
                  Verbose_Mode := True;

               when Gprexch.Relocatable =>
                  Relocatable := True;
                  Static      := False;

               when Gprexch.Static =>
                  Static      := True;
                  Relocatable := False;

               when Gprexch.Archive_Builder =>
                  Archive_Builder := null;
                  Last_AB_Option  := 0;

               when Gprexch.Archive_Indexer =>
                  Archive_Indexer := null;
                  Last_AI_Option  := 0;

               when Gprexch.Partial_Linker =>
                  Partial_Linker := null;
                  Last_PL_Option := 0;

               when Gprexch.Auto_Init =>
                  Auto_Init := True;

               when Gprexch.Symbolic_Link_Supported =>
                  Symbolic_Link_Supported  := True;

               when Gprexch.Major_Minor_Id_Supported =>
                  Major_Minor_Id_Supported := True;

               when others =>
                  null;
            end case;

         else
            case Current_Section is
               when No_Library_Section =>
                  Osint.Fail ("no section specified: ", Line (1 .. Last));

               when Quiet =>
                  Osint.Fail ("quiet section should be empty");

               when Verbose =>
                  Osint.Fail ("verbose section should be empty");

               when Gprexch.Relocatable =>
                  Osint.Fail ("relocatable section should be empty");

               when Gprexch.Static =>
                  Osint.Fail ("static section should be empty");

               when Gprexch.Object_Files =>
                  Object_Files.Append (new String'(Line (1 .. Last)));

               when Gprexch.Options =>
                  Options_Table.Append (new String'(Line (1 .. Last)));

               when Gprexch.Object_Directory =>
                  Object_Directories.Append (new String'(Line (1 .. Last)));

               when Gprexch.Library_Name =>
                  Library_Name := new String'(Line (1 .. Last));

               when Gprexch.Library_Directory =>
                  Library_Directory := new String'(Line (1 .. Last));

               when Gprexch.Library_Dependency_Directory =>
                  Library_Dependency_Directory :=
                    new String'(Line (1 .. Last));

               when Gprexch.Library_Version =>
                  Library_Version := new String'(Line (1 .. Last));

               when Gprexch.Library_Options =>
                  Library_Options_Table.Append (new String'(Line (1 .. Last)));

               when Library_Path =>
                  Osint.Fail ("library path should not be specified");

               when Gprexch.Library_Version_Options =>
                  Library_Version_Options.Append
                                            (new String'(Line (1 .. Last)));

               when Gprexch.Shared_Lib_Prefix =>
                  Shared_Lib_Prefix := new String'(Line (1 .. Last));

               when Gprexch.Shared_Lib_Suffix =>
                  Shared_Lib_Suffix := new String'(Line (1 .. Last));

               when Gprexch.Shared_Lib_Minimum_Options =>
                  Shared_Lib_Minimum_Options.Append
                                               (new String'(Line (1 .. Last)));

               when Gprexch.Symbolic_Link_Supported =>
                  Osint.Fail
                    ("symbolic link supported section should be empty");

               when Gprexch.Major_Minor_Id_Supported =>
                  Osint.Fail
                    ("major minor id supported section should be empty");

               when Gprexch.PIC_Option =>
                  PIC_Option := new String'(Line (1 .. Last));

               when Gprexch.Imported_Libraries =>
                  if End_Of_File (IO_File) then
                     Osint.Fail
                       ("no library name for imported library ",
                        Line (1 .. Last));

                  else
                     Imported_Library_Directories.Append
                       (new String'(Line (1 .. Last)));
                     Get_Line (IO_File, Line, Last);
                     Imported_Library_Names.Append
                       (new String'(Line (1 .. Last)));
                  end if;

               when Gprexch.Driver_Name =>
                  Name_Len := Last;
                  Name_Buffer (1 .. Name_Len) := Line (1 .. Last);
                  Driver_Name := Name_Find;

               when Runtime_Directory =>
                  if End_Of_File (IO_File) then
                     Osint.Fail
                       ("no runtime directory for language ",
                        Line (1 .. Last));

                  elsif To_Lower (Line (1 .. Last)) = "ada" then
                     Get_Line (IO_File, Line, Last);
                     GNAT_Runtime_Dir := new String'(Line (1 .. Last));

                  else
                     Skip_Line (IO_File);
                  end if;

               when Toolchain_Version =>
                  if End_Of_File (IO_File) then
                     Osint.Fail
                       ("no toolchain version for language ",
                        Line (1 .. Last));

                  elsif To_Lower (Line (1 .. Last)) = "ada" then
                     Get_Line (IO_File, Line, Last);

                     if Last > 5 and then Line (1 .. 5) = "GNAT " then
                        Lgnat := new String'("-lgnat-" & Line (6 .. Last));
                        Lgnarl := new String'("-lgnarl-" & Line (6 .. Last));
                     end if;

                  else
                     Skip_Line (IO_File);
                  end if;

               when Gprexch.Archive_Builder =>
                  if Archive_Builder = null then
                     Archive_Builder := new String'(Line (1 .. Last));

                  else
                     Add
                       (new String'(Line (1 .. Last)),
                        AB_Options,
                        Last_AB_Option);
                  end if;

               when Gprexch.Archive_Indexer =>
                  if Archive_Indexer = null then
                     Archive_Indexer := new String'(Line (1 .. Last));

                  else
                     Add
                       (new String'(Line (1 .. Last)),
                        AI_Options,
                        Last_AI_Option);
                  end if;

               when Gprexch.Partial_Linker =>
                  if Partial_Linker = null then
                     Partial_Linker := new String'(Line (1 .. Last));

                  else
                     Add
                       (new String'(Line (1 .. Last)),
                        PL_Options,
                        Last_PL_Option);
                  end if;

               when Gprexch.Archive_Suffix =>
                  Archive_Suffix := new String'(Line (1 .. Last));

               when Gprexch.Run_Path_Option =>
                  Path_Option := new String'(Line (1 .. Last));

               when Gprexch.Auto_Init =>
                  Osint.Fail ("auto init section should be empty");

               when Interface_Dep_Files =>
                  Interface_ALIs.Append (new String'(Line (1 .. Last)));
                  Standalone := True;

               when Dependency_Files =>
                  if Last > 4 and then Line (Last - 3 .. Last) = ".ali" then
                     ALIs.Append (new String'(Line (1 .. Last)));
                  end if;

               when Binding_Options =>
                  Binding_Options_Table.Append (new String'(Line (1 .. Last)));

               when Copy_Source_Dir =>
                  Copy_Source_Directory := new String'(Line (1 .. Last));

               when Gprexch.Sources =>
                  Sources.Append (new String'(Line (1 .. Last)));

            end case;
         end if;
      end if;
   end loop;

   Close (IO_File);

   if Object_Files.Last = 0 then
      Osint.Fail ("no object files specified");
   end if;

   Last_Object_File_Index := Object_Files.Last;

   if Library_Name = null then
      Osint.Fail ("no library name specified");
   end if;

   if Library_Directory = null then
      Osint.Fail ("no library directory specified");
   end if;

   if Object_Directories.Last = 0 then
      Osint.Fail ("no object directory specified");
   end if;

   if Library_Directory.all = Object_Directories.Table (1).all then
      Osint.Fail ("object directory and library directory cannot be the same");
   end if;

   if Library_Dependency_Directory = null then
      Library_Dependency_Directory := Library_Directory;
   end if;

   --  We work in the object directory

   begin
      Change_Dir (Object_Directories.Table (1).all);

   exception
      when others =>
         Osint.Fail
           ("cannot change to object directory ",
            Object_Directories.Table (1).all);
   end;

   if Standalone then
      declare
         Binder_Generated_File   : constant String :=
                                     "b__" & Library_Name.all & ".adb";
         Binder_Generated_Object : constant String :=
                                     "b__" & Library_Name.all & Object_Suffix;
         ALI_First_Index         : Positive;
         First_ALI               : File_Name_Type;
         T                       : Text_Buffer_Ptr;
         A                       : ALI.ALI_Id;
         use ALI;

      begin
         Gnatbind_Path := Locate_Exec_On_Path (Gnatbind_Name.all);

         if Gnatbind_Path = null then
            Osint.Fail ("unable to locate ", Gnatbind_Name.all);
         end if;

         Last_Bind_Option := 0;
         Add (No_Main, Bind_Options, Last_Bind_Option);
         Add (Output_Switch, Bind_Options, Last_Bind_Option);
         Add
           ("b__" & Library_Name.all & ".adb", Bind_Options, Last_Bind_Option);
         Add ("-L" & Library_Name.all, Bind_Options, Last_Bind_Option);

         if Auto_Init and then SALs_Use_Constructors then
            Add (Auto_Initialize, Bind_Options, Last_Bind_Option);
         end if;

         for J in 1 .. Binding_Options_Table.Last loop
            Add
              (Binding_Options_Table.Table (J).all,
               Bind_Options,
               Last_Bind_Option);
         end loop;

         --  Get an eventual --RTS from the ALI file

         Name_Len := 0;
         Add_Str_To_Name_Buffer (ALIs.Table (1).all);
         First_ALI := Name_Find;

         --  Load the ALI file

         T := Osint.Read_Library_Info (First_ALI, True);

         --  Read it

         A := Scan_ALI (First_ALI, T, Ignore_ED => False, Err => False);

         if A /= No_ALI_Id then
            for Index in
              ALI.Units.Table (ALI.ALIs.Table (A).First_Unit).First_Arg ..
              ALI.Units.Table (ALI.ALIs.Table (A).First_Unit).Last_Arg
            loop
               --  Look for --RTS. If found, add the switch to call gnatbind

               declare
                  Arg : Types.String_Ptr renames Args.Table (Index);
               begin
                  if Arg'Length >= 6 and then
                    Arg (Arg'First + 2 .. Arg'First + 5) = "RTS="
                  then
                     Add (Arg.all, Bind_Options, Last_Bind_Option);
                     exit;
                  end if;
               end;
            end loop;
         end if;

         ALI_First_Index := Last_Bind_Option + 1;

         for J in 1 .. ALIs.Last loop
            Add (ALIs.Table (J), Bind_Options, Last_Bind_Option);
         end loop;

         if not Quiet_Output then
            if Verbose_Mode then
               Put (Gnatbind_Path.all);
            else
               Put (Gnatbind_Name.all);
            end if;

            for J in 1 .. Last_Bind_Option loop
               if (not Verbose_Mode) and then J > ALI_First_Index then
                  Put (" ...");
                  exit;
               end if;

               Put (" ");
               Put (Bind_Options (J).all);
            end loop;

            New_Line;
         end if;

         --  If there is more than one object directory, set ADA_OBJECTS_PATH
         --  for the additional object libraries, so that gnatbind may find
         --  all the ALI files.

         if Object_Directories.Last > 1 then
            declare
               Object_Path : String_Access :=
                               new String'(Object_Directories.Table (2).all);

            begin
               for J in 3 .. Object_Directories.Last loop
                  Object_Path :=
                    new String'
                      (Object_Path.all &
                       Path_Separator &
                       Object_Directories.Table (J).all);
               end loop;

               Setenv ("ADA_OBJECTS_PATH", Object_Path.all);
            end;
         end if;

         Spawn
           (Gnatbind_Path.all, Bind_Options (1 .. Last_Bind_Option), Success);

         if not Success then
            Osint.Fail ("invocation of ", Gnatbind_Name.all, " failed");
         end if;

         Compiler_Path := Locate_Exec_On_Path (Compiler_Name.all);

         if Compiler_Path = null then
            Osint.Fail ("unable to locate ", Compiler_Name.all);
         end if;

         Last_Bind_Option := 0;

         Add (Compile_Switch, Bind_Options, Last_Bind_Option);
         Add (Binder_Generated_File, Bind_Options, Last_Bind_Option);
         Add (Output_Switch, Bind_Options, Last_Bind_Option);
         Add (Binder_Generated_Object, Bind_Options, Last_Bind_Option);

         if Relocatable and then PIC_Option /= null then
            Add (PIC_Option, Bind_Options, Last_Bind_Option);
         end if;

         --  Get the back-end switches and --RTS from the ALI file

         --  Load the ALI file

         T := Osint.Read_Library_Info (First_ALI, True);

         --  Read it

         A := Scan_ALI
           (First_ALI, T, Ignore_ED => False, Err => False);

         if A /= No_ALI_Id then
            for Index in
              ALI.Units.Table
                (ALI.ALIs.Table (A).First_Unit).First_Arg ..
              ALI.Units.Table
                (ALI.ALIs.Table (A).First_Unit).Last_Arg
            loop
               --  Do not compile with the front end switches except
               --  for --RTS.

               declare
                  Arg : Types.String_Ptr renames Args.Table (Index);
               begin
                  if not Is_Front_End_Switch (Arg.all)
                    or else
                      (Arg'Length > 6 and then
                       Arg (Arg'First + 2 .. Arg'First + 5) = "RTS=")
                  then
                     Add (Arg.all, Bind_Options, Last_Bind_Option);
                  end if;
               end;
            end loop;
         end if;

         if not Quiet_Output then
            if Verbose_Mode then
               Put (Compiler_Path.all);
            else
               Put (Compiler_Name.all);
            end if;

            for J in 1 .. Last_Bind_Option loop
               Put (" ");
               Put (Bind_Options (J).all);
            end loop;

            New_Line;
         end if;

         Spawn
           (Compiler_Path.all, Bind_Options (1 .. Last_Bind_Option), Success);

         if not Success then
            Osint.Fail ("invocation of ", Compiler_Name.all, " failed");
         end if;

         Object_Files.Append (new String'(Binder_Generated_Object));
      end;
   end if;

   --  Archives

   if Static then
      if Partial_Linker /= null then
         Partial_Linker_Path := Locate_Exec_On_Path (Partial_Linker.all);

         if Partial_Linker_Path = null then
            Osint.Fail ("unable to locate ", Partial_Linker.all);
         end if;
      end if;

      if Archive_Builder = null then
         Osint.Fail ("no archive builder specified");
      end if;

      Library_Path_Name :=
        new String'
          (Library_Directory.all &
           Directory_Separator &
           "lib" &
           Library_Name.all &
           Archive_Suffix.all);

      Add (Library_Path_Name, AB_Options, Last_AB_Option);

      if Partial_Linker_Path /= null then
         --  If partial linker is used, do a partial link and put the resulting
         --  object file in the archive.

         declare
            Partial : constant String_Access :=
                        new String'
                          ("p__" & Library_Name.all & Object_Suffix);

         begin
            Add (Partial, AB_Options, Last_AB_Option);
            Add (Partial, PL_Options, Last_PL_Option);

            for J in 1 .. Object_Files.Last loop
               Add (Object_Files.Table (J), PL_Options, Last_PL_Option);
            end loop;

            if not Quiet_Output then
               if Verbose_Mode then
                  Put (Partial_Linker_Path.all);
               else
                  Put (Base_Name (Partial_Linker_Path.all));
               end if;

               for J in 1 .. Last_PL_Option loop
                  if (not Verbose_Mode) and then J >= 5 then
                     Put (" ...");
                     exit;
                  end if;

                  Put (' ');
                  Put (PL_Options (J).all);
               end loop;

               New_Line;
            end if;

            Spawn
              (Partial_Linker_Path.all,
               PL_Options (1 .. Last_PL_Option),
               Success);

            if not Success then
               Osint.Fail
                 ("call to linker driver ", Partial_Linker.all, " failed");
            end if;
         end;

      else
         --  Partial linker is not specified. Put all objects in the archive.

         for J in 1 .. Object_Files.Last loop
            Add (Object_Files.Table (J), AB_Options, Last_AB_Option);
         end loop;
      end if;

      if not Quiet_Output then
         if Verbose_Mode then
            Put (Archive_Builder.all);
         else
            Put (Base_Name (Archive_Builder.all));
         end if;

         for J in 1 .. Last_AB_Option loop
            if (not Verbose_Mode) and then J >= 5 then
               Put (" ...");
               exit;
            end if;

            Put (' ');
            Put (AB_Options (J).all);
         end loop;

         New_Line;
      end if;

      Spawn
        (Archive_Builder.all,
         AB_Options (1 .. Last_AB_Option),
         Success);

      if not Success then
         Osint.Fail
           ("call to archive builder ", Archive_Builder.all, " failed");
      end if;

      if Archive_Indexer /= null then
         Add (Library_Path_Name, AI_Options, Last_AI_Option);

         if not Quiet_Output then
            if Verbose_Mode then
               Put (Archive_Indexer.all);
            else
               Put (Base_Name (Archive_Indexer.all));
            end if;

            for J in 1 .. Last_AI_Option loop
               Put (' ');
               Put (AI_Options (J).all);
            end loop;

            New_Line;
         end if;

         Spawn
           (Archive_Indexer.all,
            AI_Options (1 .. Last_AI_Option),
            Success);

         if not Success then
            Osint.Fail
              ("call to archive indexer ", Archive_Indexer.all, " failed");
         end if;
      end if;

   else
      --  Shared libraries

      Library_Path_Name :=
        new String'
          (Library_Directory.all &
           Directory_Separator &
           Shared_Lib_Prefix.all &
           Library_Name.all &
           Shared_Lib_Suffix.all);

      if Relocatable and then
         PIC_Option /= null and then
         PIC_Option.all /= ""
      then
         Options_Table.Append (new String'(PIC_Option.all));
      end if;

      --  Get default search directories to locate system.ads when calling
      --  Targparm.Get_Target_Parameters.

      --  Osint.Add_Default_Search_Dirs;

      --  Check if the platform is VMS and, if it is, change some variables

      --  Targparm.Get_Target_Parameters;

      Prj.Initialize (Prj.No_Project_Tree);

      if S_Osinte_Ads = No_File then
         Name_Len := 0;
         Add_Str_To_Name_Buffer ("s-osinte.ads");
         S_Osinte_Ads := Name_Find;
      end if;

      if S_Dec_Ads = No_File then
         Name_Len := 0;
         Add_Str_To_Name_Buffer ("dec.ads");
         S_Dec_Ads := Name_Find;
      end if;

      if G_Trasym_Ads = No_File then
         Name_Len := 0;
         Add_Str_To_Name_Buffer ("g-trasym.ads");
         G_Trasym_Ads := Name_Find;
      end if;

      --  Get the ALI files, if any

      if GNAT_Runtime_Dir /= null then
         for J in 1 .. ALIs.Last loop
            declare
               ALI_Name : constant String := ALIs.Table (J).all;
            begin
               if Is_Regular_File (ALI_Name) then
                  Check_Libs (ALI_Name);
               end if;
            end;
         end loop;
      end if;

      for J in 1 .. Imported_Library_Directories.Last loop
         Options_Table.Append
           (new String'
              ("-L" & Imported_Library_Directories.Table (J).all));

         if Path_Option /= null then
            Add_Rpath (Imported_Library_Directories.Table (J).all);
         end if;

         Options_Table.Append
           (new String'
              ("-l" & Imported_Library_Names.Table (J).all));
      end loop;

      for J in 1 .. Library_Options_Table.Last loop
         Options_Table.Append (Library_Options_Table.Table (J));
      end loop;

      if GNAT_Runtime_Dir /= null then
         declare
            Lib_Directory : constant String := GNAT_Runtime_Dir.all;
            GCC_Index     : Natural := 0;

         begin
            Options_Table.Append (new String'("-L" & Lib_Directory));

            --  If Path Option is supported, add libgnat directory path name to
            --  Rpath.

            if Path_Option /= null then
               Add_Rpath (Lib_Directory);

               --  Add to the Path Option the directory of the shared version
               --  of libgcc.

               GCC_Index := Index (Lib_Directory, "/lib/");

               if GCC_Index = 0 then
                  GCC_Index :=
                    Index
                      (Lib_Directory,
                       Directory_Separator & "lib" & Directory_Separator);
               end if;

               if GCC_Index /= 0 then
                  Add_Rpath
                    (Lib_Directory (Lib_Directory'First .. GCC_Index + 3));
               end if;

               if Libgnarl_Needed then
                  Options_Table.Append (Lgnarl);
               end if;

               if Gtrasymobj_Needed then
                  Options_Table.Append
                    (new String'(Lib_Directory & "/g-trasym.obj"));
               end if;

               if Libdecgnat_Needed then
                  Options_Table.Append
                    (new String'("-L" & Lib_Directory & "/../declib"));
                  Options_Table.Append (new String'("-ldecgnat"));
               end if;
            end if;

            Options_Table.Append (Lgnat);
         end;
      end if;

      if Path_Option /= null and then Rpath /= null then
         Options_Table.Append
           (new String'(Path_Option.all & Rpath (1 .. Rpath_Last)));
      end if;

      Build_Shared_Lib;
   end if;

   if ALIs.Last /= 0 then
      Copy_ALI_Files;
   end if;

   if Copy_Source_Directory /= null then
      Copy_Sources;
   end if;

   --  Create new exchange files with the path of the library file and the
   --  paths of the object files with their time stamps.

   begin
      Create (IO_File, Out_File, Exchange_File_Name.all);
   exception
      when others =>
         Osint.Fail ("could not create ", Exchange_File_Name.all);
   end;

   Put_Line (IO_File, Library_Path_Label);
   Put_Line (IO_File, Library_Path_Name.all);

   Put_Line (IO_File, Object_Files_Label);

   for Index in 1 .. Last_Object_File_Index loop
      Put_Line (IO_File, Object_Files.Table (Index).all);

      Name_Len := Object_Files.Table (Index)'Length;
      Name_Buffer (1 .. Name_Len) := Object_Files.Table (Index).all;
      Put_Line
        (IO_File,
         String (Osint.File_Stamp (Path_Name_Type'(Name_Find))));
   end loop;

   Close (IO_File);
end Gprlib;
