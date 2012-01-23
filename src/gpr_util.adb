------------------------------------------------------------------------------
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                             G P R _ U T I L                              --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--         Copyright (C) 2007-2012, Free Software Foundation, Inc.          --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Interfaces.C.Strings;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.Dynamic_HTables;      use GNAT.Dynamic_HTables;

with ALI;      use ALI;
with Debug;
with Makeutl;  use Makeutl;
with Opt;      use Opt;
with Osint;    use Osint;
with Output;   use Output;
with Prj.Err;
with Prj.Util; use Prj.Util;
with Scans;
with Sinput.C;
with Sinput.P;
with Snames;   use Snames;
with Tempdir;
with Types;    use Types;

package body Gpr_Util is

   Libgcc_Subdir_Ptr : Interfaces.C.Strings.chars_ptr;
   pragma Import (C, Libgcc_Subdir_Ptr, "__gnat_default_libgcc_subdir");
   --  Pointer to string indicating the installation subdirectory where a
   --  default shared libgcc might be found.

   GNU_Header  : aliased constant String := "INPUT (";
   GNU_Opening : aliased constant String := """";
   GNU_Closing : aliased constant String := '"' & ASCII.LF;
   GNU_Footer  : aliased constant String := ')' & ASCII.LF;

   package Project_Name_Boolean_Htable is new Simple_HTable
     (Header_Num => Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => Name_Id,
      Hash       => Hash,
      Equal      => "=");

   Project_Failure : Project_Name_Boolean_Htable.Instance :=
                       Project_Name_Boolean_Htable.Nil;
   --  Record a boolean for project having failed to compile cleanly

   -------------------------------
   -- Binder_Exchange_File_Name --
   -------------------------------

   function Binder_Exchange_File_Name
     (Main_Base_Name : File_Name_Type; Prefix : Name_Id) return String_Access
   is
      File_Name : constant String := Get_Name_String (Main_Base_Name);
   begin
      Get_Name_String (Prefix);
      Add_Str_To_Name_Buffer (File_Name);
      Add_Str_To_Name_Buffer (Binder_Exchange_Suffix);
      return new String'(Name_Buffer (1 .. Name_Len));
   end Binder_Exchange_File_Name;

   --------------------------
   -- Create_Response_File --
   --------------------------

   procedure Create_Response_File
     (Format            : Response_File_Format;
      Objects           : String_List;
      Other_Arguments   : String_List;
      Resp_File_Options : String_List;
      Name_1            : out Path_Name_Type;
      Name_2            : out Path_Name_Type)
   is
      Resp_File : File_Descriptor;
      Status    : Integer;
      pragma Warnings (Off, Status);
      Closing_Status : Boolean;
      pragma Warnings (Off, Closing_Status);

      function Modified_Argument (Arg : String) return String;
      --  If the argument includes a space, a backslash, or a double quote,
      --  escape the character with a preceding backsash.

      -----------------------
      -- Modified_Argument --
      -----------------------

      function Modified_Argument (Arg : String) return String is
         Result : String (1 .. 2 * Arg'Length);
         Last   : Natural := 0;

         procedure Add (C : Character);

         ---------
         -- Add --
         ---------

         procedure Add (C : Character) is
         begin
            Last := Last + 1;
            Result (Last) := C;
         end Add;

      begin
         for J in Arg'Range loop
            if Arg (J) = '\' or else Arg (J) = ' ' or else Arg (J) = '"' then
               Add ('\');
            end if;

            Add (Arg (J));
         end loop;

         return Result (1 .. Last);
      end Modified_Argument;

   begin
      Name_2 := No_Path;
      Tempdir.Create_Temp_File (Resp_File, Name => Name_1);

      if Format = GNU or else Format = GCC_GNU then
         Status := Write (Resp_File, GNU_Header'Address, GNU_Header'Length);
      end if;

      for J in Objects'Range loop
         if Format = GNU or else Format = GCC_GNU then
            Status :=
              Write (Resp_File, GNU_Opening'Address, GNU_Opening'Length);
         end if;

         Status :=
           Write (Resp_File, Objects (J).all'Address, Objects (J)'Length);

         if Format = GNU or else Format = GCC_GNU then
            Status :=
              Write (Resp_File, GNU_Closing'Address, GNU_Closing'Length);

         else
            Status :=
              Write (Resp_File, ASCII.LF'Address, 1);
         end if;
      end loop;

      if Format = GNU or else Format = GCC_GNU then
         Status := Write (Resp_File, GNU_Footer'Address, GNU_Footer'Length);
      end if;

      case Format is
         when GCC_GNU | GCC_Object_List | GCC_Option_List =>
            Close (Resp_File, Closing_Status);
            Name_2 := Name_1;
            Tempdir.Create_Temp_File (Resp_File, Name => Name_1);

            declare
               Arg : constant String :=
                       Modified_Argument (Get_Name_String (Name_2));

            begin
               for J in Resp_File_Options'Range loop
                  Status :=
                    Write
                      (Resp_File,
                       Resp_File_Options (J) (1)'Address,
                       Resp_File_Options (J)'Length);

                  if J < Resp_File_Options'Last then
                     Status := Write (Resp_File, ASCII.LF'Address, 1);
                  end if;
               end loop;

               Status := Write (Resp_File, Arg (1)'Address, Arg'Length);
            end;

            Status := Write (Resp_File, ASCII.LF'Address, 1);

         when GCC =>
            null;

         when others =>
            Close (Resp_File, Closing_Status);
      end case;

      if        Format = GCC
        or else Format = GCC_GNU
        or else Format = GCC_Object_List
        or else Format = GCC_Option_List
      then
         for J in Other_Arguments'Range loop
            declare
               Arg : constant String :=
                       Modified_Argument (Other_Arguments (J).all);

            begin
               Status := Write (Resp_File, Arg (1)'Address, Arg'Length);
            end;

            Status := Write (Resp_File, ASCII.LF'Address, 1);
         end loop;

         Close (Resp_File, Closing_Status);
      end if;
   end Create_Response_File;

   ------------------------------
   -- Get_Compiler_Driver_Path --
   ------------------------------

   function Get_Compiler_Driver_Path
     (Project_Tree : Project_Tree_Ref;
      Lang         : Language_Ptr) return String_Access is
   begin
      if Lang.Config.Compiler_Driver_Path = null then
         declare
            Compiler_Name : constant String :=
              Get_Name_String (Lang.Config.Compiler_Driver);

         begin
            if Compiler_Name = "" then
               return null;
            end if;

            Lang.Config.Compiler_Driver_Path :=
              Locate_Exec_On_Path (Compiler_Name);

            if Lang.Config.Compiler_Driver_Path = null then
               Fail_Program
                 (Project_Tree, "unable to locate """ & Compiler_Name & '"');
            end if;
         end;
      end if;

      return Lang.Config.Compiler_Driver_Path;
   end Get_Compiler_Driver_Path;

   ----------------------------
   -- Find_Binding_Languages --
   ----------------------------

   procedure Find_Binding_Languages
     (Tree         : Project_Tree_Ref;
      Root_Project : Project_Id)
   is
      Data    : constant Builder_Data_Access := Builder_Data (Tree);
      B_Index : Binding_Data;

      Language_Name      : Name_Id;
      Binder_Driver_Name : File_Name_Type := No_File;
      Binder_Driver_Path : String_Access;
      Binder_Prefix      : Name_Id;
      Language           : Language_Ptr;

      Config  : Language_Config;
      Project : Project_List;

   begin
      --  Have we already processed this tree ?

      if Data.There_Are_Binder_Drivers
        and then Data.Binding /= null
      then
         return;
      end if;

      if Current_Verbosity = High then
         Debug_Output ("Find_Binding_Languages for", Debug_Name (Tree));
      end if;

      Data.There_Are_Binder_Drivers := False;

      Project := Tree.Projects;
      while Project /= null loop
         Language := Project.Project.Languages;

         while Language /= No_Language_Index loop
            Config := Language.Config;

            Binder_Driver_Name := Config.Binder_Driver;

            if Language.First_Source /= No_Source
              and then Binder_Driver_Name /= No_File
            then
               Data.There_Are_Binder_Drivers := True;
               Language_Name := Language.Name;

               B_Index := Data.Binding;
               while B_Index /= null
                 and then B_Index.Language_Name /= Language_Name
               loop
                  B_Index := B_Index.Next;
               end loop;

               if B_Index = null then
                  Get_Name_String (Binder_Driver_Name);
                  Binder_Driver_Path :=
                    Locate_Exec_On_Path (Name_Buffer (1 .. Name_Len));

                  if Binder_Driver_Path = null then
                     Fail_Program
                       (Tree,
                        "unable to find binder driver " &
                        Name_Buffer (1 .. Name_Len));
                  end if;

                  if Current_Verbosity = High then
                     Debug_Output
                       ("Binder_Driver=" & Binder_Driver_Path.all
                        & " for Lang", Language_Name);
                  end if;

                  if Config.Binder_Prefix = No_Name then
                     Binder_Prefix := Empty_String;
                  else
                     Binder_Prefix := Config.Binder_Prefix;
                  end if;

                  B_Index := Data.Binding;
                  while B_Index /= null loop
                     if Binder_Prefix = B_Index.Binder_Prefix then
                        Fail_Program
                          (Tree,
                           "binding prefix cannot be the same for"
                           & " two languages");
                     end if;
                     B_Index := B_Index.Next;
                  end loop;

                  Data.Binding := new Binding_Data_Record'
                    (Language           => Language,
                     Language_Name      => Language_Name,
                     Binder_Driver_Name => Binder_Driver_Name,
                     Binder_Driver_Path => Binder_Driver_Path,
                     Binder_Prefix      => Binder_Prefix,
                     Next               => Data.Binding);
               end if;
            end if;

            Language := Language.Next;
         end loop;

         Project := Project.Next;
      end loop;

      if Root_Project.Qualifier = Aggregate then
         declare
            Agg : Aggregated_Project_List := Root_Project.Aggregated_Projects;
         begin
            while Agg /= null loop
               Find_Binding_Languages (Agg.Tree, Agg.Project);
               Agg := Agg.Next;
            end loop;
         end;
      end if;
   end Find_Binding_Languages;

   ------------------------------
   -- Look_For_Default_Project --
   ------------------------------

   procedure Look_For_Default_Project is
   begin
      if Is_Regular_File (Default_Project_File_Name) then
         Project_File_Name := new String'(Default_Project_File_Name);

      else
         --  Check if there is a single project file in the current
         --  directory. If there is one and only one, use it.

         declare
            Dir : Dir_Type;
            Str : String (1 .. 255);
            Last : Natural;
            Single : String_Access := null;

         begin
            Open (Dir, ".");

            loop
               Read (Dir, Str, Last);
               exit when Last = 0;

               if Last > Project_File_Extension'Length and then
                 Is_Regular_File (Str (1 .. Last))
               then
                  Canonical_Case_File_Name (Str (1 .. Last));

                  if Str (Last - Project_File_Extension'Length + 1 .. Last)
                    = Project_File_Extension
                  then
                     if Single = null then
                        Single := new String'(Str (1 .. Last));

                     else
                        --  There are several project files in the current
                        --  directory. Reset Single to null and exit.

                        Single := null;
                        exit;
                     end if;
                  end if;
               end if;
            end loop;

            Close (Dir);

            Project_File_Name := Single;
         end;
      end if;

      if (not Quiet_Output) and then Project_File_Name /= null then
         Write_Str ("using project file ");
         Write_Line (Project_File_Name.all);
      end if;
   end Look_For_Default_Project;

   ------------------
   -- Partial_Name --
   ------------------

   function Partial_Name
     (Lib_Name      : String;
      Number        : Natural;
      Object_Suffix : String) return String
   is
      Img : constant String := Number'Img;
   begin
      return
        Partial_Prefix & Lib_Name &
        '_' & Img (Img'First + 1 .. Img'Last)
        & Object_Suffix;
   end Partial_Name;

   --------------------------------
   -- Project_Compilation_Failed --
   --------------------------------

   function Project_Compilation_Failed
     (Prj       : Project_Id;
      Recursive : Boolean := True) return Boolean
   is
      use Project_Name_Boolean_Htable;
   begin
      if Get (Project_Failure, Prj.Name) then
         return True;

      elsif not Recursive then
         return False;

      else
         --  Check all imported projects directly or indirectly
         declare
            Plist : Project_List := Prj.All_Imported_Projects;
         begin
            while Plist /= null loop
               if Get (Project_Failure, Plist.Project.Name) then
                  return True;
               else
                  Plist := Plist.Next;
               end if;
            end loop;
            return False;
         end;
      end if;
   end Project_Compilation_Failed;

   -----------------------------------
   -- Set_Failed_Compilation_Status --
   -----------------------------------

   procedure Set_Failed_Compilation_Status (Prj : Project_Id) is
   begin
      Project_Name_Boolean_Htable.Set (Project_Failure, Prj.Name, True);
   end Set_Failed_Compilation_Status;

   -----------------------
   -- Shared_Libgcc_Dir --
   -----------------------

   function Shared_Libgcc_Dir (Run_Time_Dir : String) return String is
      Path      : String (1 .. Run_Time_Dir'Length + 15);
      Path_Last : constant Natural := Run_Time_Dir'Length;
      GCC_Index : Natural := 0;

   begin
      Path (1 .. Path_Last) := Run_Time_Dir;
      GCC_Index := Index (Path (1 .. Path_Last), "gcc-lib");

      if GCC_Index /= 0 then
         --  This is gcc 2.8.2: the shared version of libgcc is
         --  located in the parent directory of "gcc-lib".

         GCC_Index := GCC_Index - 1;

      else
         GCC_Index := Index (Path (1 .. Path_Last), "/lib/");

         if GCC_Index = 0 then
            GCC_Index :=
              Index
                (Path (1 .. Path_Last),
                 Directory_Separator & "lib" & Directory_Separator);
         end if;

         if GCC_Index /= 0 then
            --  We have found "lib" as a subdirectory in the runtime dir path.
            --  The
            declare
               Subdir : constant String :=
                 Interfaces.C.Strings.Value (Libgcc_Subdir_Ptr);
            begin
               Path
                 (GCC_Index + 1 ..
                    GCC_Index + Subdir'Length) :=
                   Subdir;
               GCC_Index :=
                 GCC_Index + Subdir'Length;
            end;
         end if;
      end if;

      return Path (1 .. GCC_Index);
   end Shared_Libgcc_Dir;

   ---------------------
   -- Need_To_Compile --
   ---------------------

   procedure Need_To_Compile
     (Source         : Prj.Source_Id;
      Tree           : Project_Tree_Ref;
      In_Project     : Project_Id;
      Must_Compile   : out Boolean;
      The_ALI        : out ALI.ALI_Id;
      Object_Check   : Boolean;
      Always_Compile : Boolean)
   is
      Source_Path        : constant String :=
                             Get_Name_String (Source.Path.Display_Name);
      C_Source_Path      : constant String :=
                             Get_Name_String (Source.Path.Name);
      Runtime_Source_Dir : constant Name_Id :=
                             Source.Language.Config.Runtime_Source_Dir;

      Start    : Natural;
      Finish   : Natural;
      Last_Obj : Natural;
      Stamp    : Time_Stamp_Type;

      Looping : Boolean := False;
      --  Set to True at the end of the first Big_Loop for Makefile fragments

      Source_In_Dependencies : Boolean := False;
      --  Set True if source was found in dependency file of its object file

      C_Object_Name : String_Access := null;
      Object_Name   : String_Access := null;
      Object_Path   : String_Access := null;
      Switches_Name : String_Access := null;
      --  ??? Missing doc for these

      Num_Ext : Natural;
      --  Number of extending projects

      ALI_Project : Project_Id;
      --  If the ALI file is in the object directory of a project, this is
      --  the project id.

      Externally_Built : constant Boolean := In_Project.Externally_Built;
      --  True if the project of the source is externally built

      function Process_Makefile_Deps
        (Dep_Name, Obj_Dir : String) return Boolean;
      function Process_ALI_Deps return Boolean;
      --  Process the dependencies for the current source file for the various
      --  dependency modes.
      --  They return True if the file needs to be recompiled

      procedure Cleanup;
      --  Cleanup local variables

      ---------------------------
      -- Process_Makefile_Deps --
      ---------------------------

      function Process_Makefile_Deps
        (Dep_Name, Obj_Dir : String) return Boolean
      is
         Dep_File : Prj.Util.Text_File;
      begin
         Open (Dep_File, Dep_Name);

         --  If dependency file cannot be open, we need to recompile
         --  the source.

         if not Is_Valid (Dep_File) then
            if Verbose_Mode then
               Write_Str  ("      -> could not open dependency file ");
               Write_Line (Dep_Name);
            end if;

            return True;
         end if;

         --  Loop Big_Loop is executed several times only when the
         --  dependency file contains several times
         --     <object file>: <source1> ...
         --  When there is only one of such occurence, Big_Loop is exited
         --  successfully at the beginning of the second loop.

         Big_Loop :
         loop
            declare
               End_Of_File_Reached : Boolean := False;
               Object_Found        : Boolean := False;

            begin
               loop
                  if End_Of_File (Dep_File) then
                     End_Of_File_Reached := True;
                     exit;
                  end if;

                  Get_Line (Dep_File, Name_Buffer, Name_Len);

                  if Name_Len > 0
                    and then Name_Buffer (1) /= '#'
                  then
                     --  Skip a first line that is an empty continuation line

                     for J in 1 .. Name_Len - 1 loop
                        if Name_Buffer (J) /= ' ' then
                           Object_Found := True;
                           exit;
                        end if;
                     end loop;

                     exit when Object_Found
                       or else Name_Buffer (Name_Len) /= '\';
                  end if;
               end loop;

               --  If dependency file contains only empty lines or comments,
               --  then dependencies are unknown, and the source needs to be
               --  recompiled.

               if End_Of_File_Reached then
                  --  If we have reached the end of file after the first
                  --  loop, there is nothing else to do.

                  exit Big_Loop when Looping;

                  if Verbose_Mode then
                     Write_Str  ("      -> dependency file ");
                     Write_Str  (Dep_Name);
                     Write_Line (" is empty");
                  end if;

                  Close (Dep_File);
                  return True;
               end if;
            end;

            Start  := 1;
            Finish := Index (Name_Buffer (1 .. Name_Len), ": ");

            if Finish = 0 then
               Finish :=
                 Index
                   (Name_Buffer (1 .. Name_Len), (1 => ':', 2 => ASCII.HT));
            end if;

            if Finish /= 0 then
               Last_Obj := Finish;
               loop
                  Last_Obj := Last_Obj - 1;
                  exit when Last_Obj = Start
                    or else Name_Buffer (Last_Obj) /= ' ';
               end loop;

               while Start < Last_Obj and then Name_Buffer (Start) = ' ' loop
                  Start := Start + 1;
               end loop;

               Canonical_Case_File_Name (Name_Buffer (Start .. Last_Obj));
            end if;

            --  First line must start with name of object file, followed by
            --  colon.

            if Finish = 0 or else
              (C_Object_Name /= null
               and then Name_Buffer (Start .. Last_Obj) /= C_Object_Name.all)
            then
               if Verbose_Mode then
                  Write_Str  ("      -> dependency file ");
                  Write_Str  (Dep_Name);
                  Write_Line (" has wrong format");

                  if Finish = 0 then
                     Write_Line ("         no colon");

                  else
                     Write_Str  ("         expected object file name ");
                     Write_Str  (C_Object_Name.all);
                     Write_Str  (", got ");
                     Write_Line (Name_Buffer (Start .. Last_Obj));
                  end if;
               end if;

               Close (Dep_File);
               return True;

            else
               Start := Finish + 2;

               --  Process each line

               Line_Loop : loop
                  declare
                     Line : String  := Name_Buffer (1 .. Name_Len);
                     Last : Natural := Name_Len;

                  begin
                     Name_Loop : loop

                        --  Find the beginning of the next source path name

                        while Finish < Last and then Line (Start) = ' ' loop
                           Start := Start + 1;
                        end loop;

                        --  Go to next line when there is a continuation
                        --  character \ at the end of the line.

                        exit Name_Loop when Start = Last
                          and then Line (Start) = '\';

                        --  We should not be at the end of the line, without
                        --  a continuation character \.

                        if Start = Last then
                           if Verbose_Mode then
                              Write_Str  ("      -> dependency file ");
                              Write_Str  (Dep_Name);
                              Write_Line (" has wrong format");
                           end if;

                           Close (Dep_File);
                           return True;
                        end if;

                        --  Look for the end of the source path name

                        Finish := Start;

                        while Finish < Last loop
                           if Line (Finish) = '\' then
                              --  On Windows, a '\' is part of the path
                              --  name, except when it is not the first
                              --  character followed by another '\' or by a
                              --  space. On other platforms, when we are
                              --  getting a '\' that is not the last
                              --  character of the line, the next character
                              --  is part of the path name, even if it is a
                              --  space.

                              if On_Windows
                                and then Finish = Start
                                and then Line (Finish + 1) = '\'
                              then
                                 Finish := Finish + 2;

                              elsif On_Windows
                                and then Line (Finish + 1) /= '\'
                                and then Line (Finish + 1) /= ' '
                              then
                                 Finish := Finish + 1;

                              else
                                 Line (Finish .. Last - 1) :=
                                   Line (Finish + 1 .. Last);
                                 Last := Last - 1;
                              end if;

                           else
                              --  A space that is not preceded by '\'
                              --  indicates the end of the path name.

                              exit when Line (Finish + 1) = ' ';
                              Finish := Finish + 1;
                           end if;
                        end loop;

                        --  Check this source

                        declare
                           Src_Name : constant String :=
                             Normalize_Pathname
                               (Name           => Line (Start .. Finish),
                                Directory      => Obj_Dir,
                                Resolve_Links  => False);
                           C_Src_Name : String := Src_Name;
                           Src_TS   : Time_Stamp_Type;
                           Source_2 : Prj.Source_Id;

                        begin
                           Canonical_Case_File_Name (C_Src_Name);

                           --  If it is original source, set
                           --  Source_In_Dependencies.

                           if C_Src_Name = C_Source_Path then
                              Source_In_Dependencies := True;
                           end if;

                           --  Get the time stamp of the source, which is not
                           --  necessarily a source of any project.

                           Name_Len := 0;
                           Add_Str_To_Name_Buffer (Src_Name);
                           Src_TS := File_Stamp (File_Name_Type'(Name_Find));

                           --  If the source does not exist, we need to
                           --  recompile.

                           if Src_TS = Empty_Time_Stamp then
                              if Verbose_Mode then
                                 Write_Str  ("      -> source ");
                                 Write_Str  (Src_Name);
                                 Write_Line (" does not exist");
                              end if;

                              Close (Dep_File);
                              return True;

                              --  If the source has been modified after the
                              --  object file, we need to recompile.

                           elsif Src_TS > Source.Object_TS
                             and then Object_Check
                             and then Source.Language.Config.Object_Generated
                           then
                              if Verbose_Mode then
                                 Write_Str  ("      -> source ");
                                 Write_Str  (Src_Name);
                                 Write_Line
                                   (" has time stamp later than object file");
                              end if;

                              Close (Dep_File);
                              return True;

                           else
                              Name_Len := Src_Name'Length;
                              Name_Buffer (1 .. Name_Len) := Src_Name;
                              Source_2 := Source_Paths_Htable.Get
                                (Tree.Source_Paths_HT, Name_Find);

                              if Source_2 /= No_Source and then
                                Source_2.Replaced_By /= No_Source
                              then
                                 if Verbose_Mode then
                                    Write_Str  ("      -> source ");
                                    Write_Str  (Src_Name);
                                    Write_Line (" has been replaced");
                                 end if;

                                 Close (Dep_File);
                                 return True;
                              end if;
                           end if;
                        end;

                        --  If the source path name ends the line, we are
                        --  done.

                        exit Line_Loop when Finish = Last;

                        --  Go get the next source on the line

                        Start := Finish + 1;
                     end loop Name_Loop;
                  end;

                  --  If we are here, we had a continuation character \ at
                  --  the end of the line, so we continue with the next
                  --  line.

                  Get_Line (Dep_File, Name_Buffer, Name_Len);
                  Start  := 1;
                  Finish := 1;
               end loop Line_Loop;
            end if;

            --  Set Looping at the end of the first loop
            Looping := True;
         end loop Big_Loop;

         Close (Dep_File);

         --  If the original sources were not in the dependency file, then
         --  we need to recompile. It may mean that we are using a different
         --  source (different variant) for this object file.

         if not Source_In_Dependencies then
            if Verbose_Mode then
               Write_Str  ("      -> source ");
               Write_Str  (Source_Path);
               Write_Line (" is not in the dependencies");
            end if;

            return True;
         end if;

         return False;
      end Process_Makefile_Deps;

      ----------------------
      -- Process_ALI_Deps --
      ----------------------

      function Process_ALI_Deps return Boolean is
         Text     : Text_Buffer_Ptr :=
                      Read_Library_Info_From_Full
                        (File_Name_Type (Source.Dep_Path),
                         Source.Dep_TS'Access);
         Sfile    : File_Name_Type;
         Dep_Src  : Prj.Source_Id;
         Proj     : Project_Id;

         Found : Boolean := False;

      begin
         if Text = null then
            if Verbose_Mode then
               Write_Str ("    -> cannot read ");
               Write_Line (Get_Name_String (Source.Dep_Path));
            end if;

            return True;
         end if;

         --  Read only the necessary lines of the ALI file

         The_ALI :=
           ALI.Scan_ALI
             (File_Name_Type (Source.Dep_Path),
              Text,
              Ignore_ED     => False,
              Err           => True,
              Ignore_Errors => True,
              Read_Lines    => "PDW");
         Free (Text);

         if The_ALI = ALI.No_ALI_Id then
            if Verbose_Mode then
               Write_Str ("    -> ");
               Write_Str (Get_Name_String (Source.Dep_Path));
               Write_Line (" is incorrectly formatted");
            end if;

            return True;
         end if;

         if ALI.ALIs.Table (The_ALI).Compile_Errors then
            if Verbose_Mode then
               Write_Line ("    -> last compilation had errors");
            end if;

            return True;
         end if;

         if Object_Check and then ALI.ALIs.Table (The_ALI).No_Object then
            if Verbose_Mode then
               Write_Line
                 ("    -> no object generated during last compilation");
            end if;

            return True;
         end if;

         if not Check_Source_Info_In_ALI (The_ALI, Tree) then
            return True;
         end if;

         --  We need to check that the ALI file is in the correct object
         --  directory. If it is in the object directory of a project
         --  that is extended and it depends on a source that is in one
         --  of its extending projects, then the ALI file is not in the
         --  correct object directory.

         ALI_Project := Source.Object_Project;

         --  Count the extending projects

         Num_Ext := 0;
         Proj := ALI_Project;
         loop
            Proj := Proj.Extended_By;
            exit when Proj = No_Project;
            Num_Ext := Num_Ext + 1;
         end loop;

         declare
            Projects : array (1 .. Num_Ext) of Project_Id;
         begin
            Proj := ALI_Project;
            for J in Projects'Range loop
               Proj := Proj.Extended_By;
               Projects (J) := Proj;
            end loop;

            for D in ALI.ALIs.Table (The_ALI).First_Sdep ..
              ALI.ALIs.Table (The_ALI).Last_Sdep
            loop
               Sfile := ALI.Sdep.Table (D).Sfile;

               if ALI.Sdep.Table (D).Stamp /= Empty_Time_Stamp then
                  Dep_Src := Source_Files_Htable.Get
                    (Tree.Source_Files_HT, Sfile);
                  Found := False;

                  while Dep_Src /= No_Source loop
                     Initialize_Source_Record (Dep_Src);

                     if not Dep_Src.Locally_Removed
                       and then Dep_Src.Unit /= No_Unit_Index
                     then
                        Found := True;

                        if Opt.Minimal_Recompilation
                          and then ALI.Sdep.Table (D).Stamp /=
                          Dep_Src.Source_TS
                        then
                           --  If minimal recompilation is in action, replace
                           --  the stamp of the source file in the table if
                           --  checksums match.

                           declare
                              Source_Index : Source_File_Index;
                              use Prj.Err;
                              use Scans;

                           begin
                              Source_Index :=
                                Sinput.C.Load_File
                                  (Get_Name_String
                                      (Dep_Src.Path.Display_Name));

                              if Source_Index /= No_Source_File then

                                 Scanner.Initialize_Scanner (Source_Index);

                                 --  Make sure that the project language
                                 --  reserved words are not recognized as
                                 --  reserved words, but as identifiers.

                                 Set_Name_Table_Byte (Name_Project,  0);
                                 Set_Name_Table_Byte (Name_Extends,  0);
                                 Set_Name_Table_Byte (Name_External, 0);

                                 --  Scan the complete file to compute its
                                 --  checksum.

                                 loop
                                    Scanner.Scan;
                                    exit when Token = Tok_EOF;
                                 end loop;

                                 if Scans.Checksum =
                                   ALI.Sdep.Table (D).Checksum
                                 then
                                    if Verbose_Mode then
                                       Write_Str ("   ");
                                       Write_Str
                                         (Get_Name_String
                                            (ALI.Sdep.Table (D).Sfile));
                                       Write_Str (": up to date, " &
                                                  "different timestamps " &
                                                  "but same checksum");
                                       Write_Eol;
                                    end if;

                                    ALI.Sdep.Table (D).Stamp :=
                                      Dep_Src.Source_TS;
                                 end if;
                              end if;

                              --  To avoid using too much memory, free the
                              --  memory allocated.

                              Sinput.P.Clear_Source_File_Table;
                           end;
                        end if;

                        if ALI.Sdep.Table (D).Stamp /= Dep_Src.Source_TS then
                           if Verbose_Mode then
                              Write_Str
                                ("   -> different time stamp for ");
                              Write_Line (Get_Name_String (Sfile));

                              if Debug.Debug_Flag_T then
                                 Write_Str ("   in ALI file: ");
                                 Write_Line
                                   (String (ALI.Sdep.Table (D).Stamp));
                                 Write_Str ("   actual file: ");
                                 Write_Line (String (Dep_Src.Source_TS));
                              end if;
                           end if;

                           return True;

                        else
                           for J in Projects'Range loop
                              if Dep_Src.Project = Projects (J) then
                                 if Verbose_Mode then
                                    Write_Line
                                      ("   -> wrong object directory");
                                 end if;

                                 return True;
                              end if;
                           end loop;

                           exit;
                        end if;
                     end if;

                     Dep_Src := Dep_Src.Next_With_File_Name;
                  end loop;

                  --  If the source was not found and the runtime source
                  --  directory is defined, check if the file exists there, and
                  --  if it does, check its timestamp.

                  if not Found and then Runtime_Source_Dir /= No_Name then
                     Get_Name_String (Runtime_Source_Dir);
                     Add_Char_To_Name_Buffer (Directory_Separator);
                     Add_Str_To_Name_Buffer (Get_Name_String (Sfile));

                     declare
                        TS   : constant Time_Stamp_Type :=
                          Source_File_Stamp (Name_Find);
                     begin
                        if TS /= Empty_Time_Stamp
                          and then TS /= ALI.Sdep.Table (D).Stamp
                        then
                           if Verbose_Mode then
                              Write_Str
                                ("   -> different time stamp for ");
                              Write_Line (Get_Name_String (Sfile));

                              if Debug.Debug_Flag_T then
                                 Write_Str ("   in ALI file: ");
                                 Write_Line
                                   (String (ALI.Sdep.Table (D).Stamp));
                                 Write_Str ("   actual file: ");
                                 Write_Line (String (TS));
                              end if;
                           end if;

                           return True;
                        end if;
                     end;
                  end if;
               end if;
            end loop;
         end;

         return False;
      end Process_ALI_Deps;

      -------------
      -- Cleanup --
      -------------

      procedure Cleanup is
      begin
         Free (Object_Name);
         Free (C_Object_Name);
         Free (Object_Path);
         Free (Switches_Name);
      end Cleanup;

   begin
      The_ALI := ALI.No_ALI_Id;

      --  Never attempt to compile header files

      if Source.Language.Config.Kind = File_Based and then
         Source.Kind = Spec
      then
         Must_Compile := False;
         return;
      end if;

      if Force_Compilations then
         Must_Compile := Always_Compile or else (not Externally_Built);
         return;
      end if;

      --  No need to compile if there is no "compiler"

      if Length_Of_Name (Source.Language.Config.Compiler_Driver) = 0 then
         Must_Compile := False;
         return;
      end if;

      if Source.Language.Config.Object_Generated and then Object_Check then
         Object_Name := new String'(Get_Name_String (Source.Object));
         C_Object_Name := new String'(Object_Name.all);
         Canonical_Case_File_Name (C_Object_Name.all);
         Object_Path := new String'(Get_Name_String (Source.Object_Path));

         if Source.Switches_Path /= No_Path then
            Switches_Name :=
              new String'(Get_Name_String (Source.Switches_Path));
         end if;
      end if;

      if Verbose_Mode and then Verbosity_Level > Opt.Low then
         Write_Str  ("   Checking ");
         Write_Str  (Source_Path);

         if Source.Index /= 0 then
            Write_Str (" at ");
            Write_Int (Source.Index);
         end if;

         Write_Line (" ... ");
      end if;

      --  No need to compile if project is externally built

      if Externally_Built then
         if Verbose_Mode then
            Write_Line ("      project is externally built");
         end if;

         Must_Compile := False;
         Cleanup;
         return;
      end if;

      if not Source.Language.Config.Object_Generated then
         --  If no object file is generated, the "compiler" need to be invoked
         --  if there is no dependency file.

         if Source.Language.Config.Dependency_Kind = None then
            if Verbose_Mode then
               Write_Line ("      -> no object file generated");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

      elsif Object_Check then
         --  If object file does not exist, of course source need to be
         --  compiled.

         if Source.Object_TS = Empty_Time_Stamp then
            if Verbose_Mode then
               Write_Str  ("      -> object file ");
               Write_Str  (Object_Path.all);
               Write_Line (" does not exist");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  If the object file has been created before the last modification
         --  of the source, the source need to be recompiled.

         if (not Opt.Minimal_Recompilation) and then
           Source.Object_TS < Source.Source_TS
         then
            if Verbose_Mode then
               Write_Str  ("      -> object file ");
               Write_Str  (Object_Path.all);
               Write_Line (" has time stamp earlier than source");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;
      end if;

      if Source.Language.Config.Dependency_Kind /= None then

         --  If there is no dependency file, then the source needs to be
         --  recompiled and the dependency file need to be created.

         Stamp := File_Time_Stamp (Source.Dep_Path, Source.Dep_TS'Access);

         if Stamp = Empty_Time_Stamp then
            if Verbose_Mode then
               Write_Str  ("      -> dependency file ");
               Write_Str  (Get_Name_String (Source.Dep_Path));
               Write_Line (" does not exist");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  If the ALI file has been created after the object file, we need
         --  to recompile.

         if Object_Check and then
            Source.Language.Config.Dependency_Kind = ALI_File and then
            Source.Object_TS < Stamp
         then
            if Verbose_Mode then
               Write_Str  ("      -> ALI file ");
               Write_Str  (Get_Name_String (Source.Dep_Path));
               Write_Line (" has timestamp earlier than object file");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  The source needs to be recompiled if the source has been modified
         --  after the dependency file has been created.

         if not Opt.Minimal_Recompilation
           and then Stamp < Source.Source_TS
         then
            if Verbose_Mode then
               Write_Str  ("      -> dependency file ");
               Write_Str  (Get_Name_String (Source.Dep_Path));
               Write_Line (" has time stamp earlier than source");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;
      end if;

      --  If we are checking the switches and there is no switches file, then
      --  the source needs to be recompiled and the switches file need to be
      --  created.

      if Check_Switches and then Switches_Name /= null then
         if Source.Switches_TS = Empty_Time_Stamp then
            if Verbose_Mode then
               Write_Str  ("      -> switches file ");
               Write_Str  (Switches_Name.all);
               Write_Line (" does not exist");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  The source needs to be recompiled if the source has been modified
         --  after the switches file has been created.

         if Source.Switches_TS < Source.Source_TS then
            if Verbose_Mode then
               Write_Str  ("      -> switches file ");
               Write_Str  (Switches_Name.all);
               Write_Line (" has time stamp earlier than source");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;
      end if;

      case Source.Language.Config.Dependency_Kind is
         when None =>
            null;

         when Makefile =>
            if Process_Makefile_Deps
                 (Get_Name_String (Source.Dep_Path),
                  Get_Name_String
                    (Source.Project.Object_Directory.Display_Name))
            then
               Must_Compile := True;
               Cleanup;
               return;
            end if;

         when ALI_File =>
            if Process_ALI_Deps then
               Must_Compile := True;
               Cleanup;
               return;
            end if;
      end case;

      --  If we are here, then everything is OK, and we don't need
      --  to recompile.

      if (not Object_Check) and then Verbose_Mode then
         Write_Line ("      -> up to date");
      end if;

      Must_Compile := False;
      Cleanup;
   end Need_To_Compile;

   ---------------
   -- Knowledge --
   ---------------

   package body Knowledge is separate;

end Gpr_Util;
