------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2012-2017, AdaCore                     --
--                                                                          --
-- This is  free  software;  you can redistribute it and/or modify it under --
-- terms of the  GNU  General Public License as published by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for more details.  You should have received  a copy of the  GNU  --
-- General Public License distributed with GNAT; see file  COPYING. If not, --
-- see <http://www.gnu.org/licenses/>.                                      --
--                                                                          --
------------------------------------------------------------------------------

with Ada.Containers.Indefinite_Ordered_Sets; use Ada;
with Ada.Directories;                        use Ada.Directories;
with Ada.Text_IO;                            use Ada.Text_IO;

with GNAT.MD5; use GNAT.MD5;

with Gpr_Util;  use Gpr_Util;
with GPR.Opt;
with GPR.Osint; use GPR;
with GPR.Util;  use GPR.Util;

package body Gprinstall.Uninstall is

   package File_Set is new Containers.Indefinite_Ordered_Sets (String);

   -------------
   -- Process --
   -------------

   procedure Process (Install_Name : String) is

      procedure Delete_File (Position : File_Set.Cursor);
      --  Delete file pointed to by Position, do nothing if the file is not
      --  found.

      procedure Do_Delete (Filename : String);
      --  Delete file or display a message if in dry-run mode

      procedure Delete_Empty_Directory (Dir_Name : String);
      --  Delete Dir_Name if empty, if removed try with parent directory

      function Project_Dir return String;
      --  Returns the full pathname to the project directory

      ----------------------------
      -- Delete_Empty_Directory --
      ----------------------------

      procedure Delete_Empty_Directory (Dir_Name : String) is
      begin
         Delete_Empty_Directory (Global_Prefix_Dir.V.all, Dir_Name);
      end Delete_Empty_Directory;

      -----------------
      -- Delete_File --
      -----------------

      procedure Delete_File (Position : File_Set.Cursor) is
         Name : constant String := File_Set.Element (Position);
      begin
         Do_Delete (Global_Prefix_Dir.V.all & Name);
      end Delete_File;

      ---------------
      -- Do_Delete --
      ---------------

      procedure Do_Delete (Filename : String) is
         Success : Boolean;
      begin
         if Dry_Run then
            Put_Line ("delete " & Filename);

         else
            Delete_File (Filename, Success);
            Delete_Empty_Directory (Containing_Directory (Filename));
         end if;
      end Do_Delete;

      -----------------
      -- Project_Dir --
      -----------------

      function Project_Dir return String is
      begin
         if Is_Absolute_Path (Global_Project_Subdir.V.all) then
            return Global_Project_Subdir.V.all;
         else
            return Global_Prefix_Dir.V.all & Global_Project_Subdir.V.all;
         end if;
      end Project_Dir;

      Dir  : constant String := Project_Dir & "manifests";
      Name : constant String := Dir & DS & Install_Name;

      Man     : File_Type;
      Buffer  : String (1 .. 4096);
      Last    : Natural;
      Files   : File_Set.Set;
      Changed : File_Set.Set;

      --  Ranges in Buffer above, we have the MD5 (32 chars) a space and then
      --  the filename.

      subtype MD5_Range is Positive range Message_Digest'Range;
      subtype Name_Range is Positive range MD5_Range'Last + 2 .. Buffer'Last;

      File_Digest     : Message_Digest;
      Expected_Digest : Message_Digest;
      Removed         : Boolean;

   begin
      --  Check if manifest for this project exists

      if not Exists (Name) then
         if not Opt.Quiet_Output then
            Fail_Program (Project_Tree, "Project " & Name & " not found.");
         end if;

         Finish_Program
           (Project_Tree, Exit_Code => Osint.E_Errors);
      end if;

      if not Opt.Quiet_Output then
         Put_Line ("Uninstall project " & Install_Name);
      end if;

      --  Check each file to be deleted

      Open (Man, In_File, Name);

      while not End_Of_File (Man) loop
         Get_Line (Man, Buffer, Last);

         --  Skip first line if it is the original project's signature

         if Last > MD5_Range'Last
           and then Buffer (1 .. 2) /= Sig_Line
         then
            declare
               F_Name : constant String := Buffer (Name_Range'First .. Last);
            begin
               Expected_Digest := Buffer (MD5_Range);

               if Exists (Global_Prefix_Dir.V.all & F_Name) then
                  File_Digest := File_MD5 (Global_Prefix_Dir.V.all & F_Name);
                  Removed := False;
               else
                  Removed := True;
               end if;

               --  Unconditionally add a file to the remove list if digest is
               --  ok, if we are running in force mode or the file has already
               --  been removed.

               if File_Digest = Expected_Digest
                 or else Force_Installations
                 or else Removed
               then
                  Files.Include (F_Name);

               else
                  Changed.Include (F_Name);
               end if;
            end;
         end if;
      end loop;

      Close (Man);

      --  Delete files

      if Changed.Is_Subset (Of_Set => Files) then
         Files.Iterate (Delete_File'Access);

         --  Then finally delete the manifest for this project

         Do_Delete (Name);

      else
         if not Opt.Quiet_Output then
            Put_Line ("Following files have been changed:");

            declare
               procedure Display (Position : File_Set.Cursor);
               --  Display only if not part of Files set

               -------------
               -- Display --
               -------------

               procedure Display (Position : File_Set.Cursor) is
                  F_Name : constant String := File_Set.Element (Position);
               begin
                  if not Files.Contains (F_Name) then
                     Put_Line (F_Name);
                  end if;
               end Display;

            begin
               Changed.Iterate (Display'Access);
            end;

            Put_Line ("use option -f to force file deletion.");
         end if;
      end if;
   end Process;

end Gprinstall.Uninstall;
