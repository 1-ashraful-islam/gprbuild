------------------------------------------------------------------------------
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--           G P R B U I L D . C O M P I L A T I O N . S L A V E            --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--         Copyright (C) 2012-2013, Free Software Foundation, Inc.          --
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

with Ada.Calendar;                use Ada.Calendar;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;      use Ada;
with Ada.Directories;             use Ada.Directories;
with Ada.Exceptions;              use Ada.Exceptions;
with Ada.Strings.Fixed;           use Ada.Strings.Fixed;
with Ada.Strings.Maps.Constants;  use Ada.Strings;
with Ada.Strings.Unbounded;       use Ada.Strings.Unbounded;

with GNAT.Sockets;      use GNAT; use GNAT.Sockets;
with GNAT.String_Split; use GNAT.String_Split;

with Output; use Output;
with Snames; use Snames;

with Gpr_Util;                      use Gpr_Util;
with Gprbuild.Compilation.Protocol; use Gprbuild.Compilation.Protocol;
with Gprbuild.Compilation.Result;

package body Gprbuild.Compilation.Slave is

   type Slave_Data is record
      Host : Unbounded_String;
      User : Unbounded_String;
      Port : Port_Type;
      Sync : Sync_Kind;
   end record;

   No_Slave_Data : constant Slave_Data :=
                     (Port => Port_Type'Last, others => <>);

   package Slaves_N is new Containers.Vectors (Positive, Slave_Data);

   Slaves_Data : Slaves_N.Vector;

   type Slave is record
      Sock          : Integer;
      Data          : Slave_Data;
      Channel       : Communication_Channel;
      Current       : Natural := 0;
      Max_Processes : Positive := 1;
      Root_Dir      : Unbounded_String;
      Rsync_Pid     : Process_Id;
   end record;

   function "<" (K1, K2 : Slave) return Boolean is (K1.Sock < K2.Sock);
   function "=" (K1, K2 : Slave) return Boolean is (K1.Sock = K2.Sock);

   No_Slave : constant Slave :=
                (-1, No_Slave_Data, Current => Natural'Last, others => <>);

   package Slave_S is new Containers.Ordered_Sets (Slave);
   --  The key is the C socket number

   function Connect_Slave
     (S_Data       : Slave_Data;
      Project_Name : String) return Slave;
   --  Connect to the slave and return the corresponding object

   procedure Wait_Rsync (N : Natural);
   --  Wait for N rsync processes. If one of the is in error exit

   --  Ack transient signal stored into this variable

   protected Wait_Ack is
      procedure Set (Pid : Remote_Id);
      entry Get (Pid : out Remote_Id);
   private
      Is_Set : Boolean := False;
      Id     : Remote_Id;
   end Wait_Ack;

   task type Wait_Remote;
   --  Wait for incoming data from all registred slaves

   type Wait_Remote_Ref is access Wait_Remote;
   WR : Wait_Remote_Ref;
   --  Will be initialized only if the distributed mode is activated

   Compiler_Path : constant OS_Lib.String_Access :=
                     Locate_Exec_On_Path ("gnatls");

   Rsync         : constant GNAT.OS_Lib.String_Access :=
                     Locate_Exec_On_Path ("rsync");

   Project_Name : Unbounded_String;
   --  Current project name being compiled

   Root_Dir     : Unbounded_String;
   --  Root directory from where the sources are to be synchronized with the
   --  slaves. This is by default the directory containing the main project
   --  file. The value is changed with the Root_Dir attribute value of the
   --  project file's Remote package.

   Remote_Process : Shared_Counter;
   Slaves_Sockets : Socket_Set_Type;
   Max_Processes  : Natural := 0;

   protected Slaves is

      procedure Insert (S : Slave);
      --  Add a slave into the pool

      function Find (Socket : Integer) return Slave;
      --  Find a slave given the socket number

      function Find (Pid : Process_Id) return Slave;
      --  Find a slave given the rsync process id

      function Get_Free return Slave;
      --  Returns a slave with free compilation slot

      procedure Increment_Current (S : in out Slave);
      --  Increment the number of processes handled by slave

      procedure Decrement_Current (S : in out Slave);
      --  Decrement the number of processes handled by slave

      procedure Set_Rewrite_CD (S : in out Slave; Path : String);
      --  Record rewriting of the compiler directory

      procedure Set_Rewrite_WD (S : in out Slave; Path : String);
      --  Record rewriting of the wording directory

      procedure Iterate (Proc : access procedure (S : in out Slave));
      --  Iterate over all slaves in the pool and call proc

      procedure Clear;
      --  Clear the pool

   private
      Pool : Slave_S.Set;
   end Slaves;

   ----------------------------
   -- Clean_Up_Remote_Slaves --
   ----------------------------

   procedure Clean_Up_Remote_Slaves
     (Tree    : Project_Tree_Ref;
      Project : Project_Id)
   is
      pragma Unreferenced (Tree);

      procedure Clean_Up_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String);
      --  Clean-up slave

      ---------------------------
      -- Clean_Up_Remote_Slave --
      ---------------------------

      procedure Clean_Up_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String)
      is

         function User_Host return String is
           (if S_Data.User = Null_Unbounded_String
            then To_String (S_Data.Host)
            else To_String (S_Data.User) & '@' & To_String (S_Data.Host));

         S : Slave;

      begin
         --  Only clean-up when the sources are not shared

         if S_Data.Sync = Protocol.Rsync then
            S := Connect_Slave (S_Data, Project_Name);

            --  Send the clean-up request

            Protocol.Send_Clean_Up (S.Channel, Project_Name);

            declare
               Cmd : constant Command := Get_Command (S.Channel);
            begin
               if Kind (Cmd) = OK then
                  if Opt.Verbose_Mode then
                     Write_Line
                       ("Clean-up done on " & To_String (S_Data.Host));
                  end if;

               elsif Kind (Cmd) = KO then
                  Write_Line ("Slave cannot clean-up " & User_Host);
                  OS_Exit (1);

               else
                  Write_Line
                    ("protocol error: " & Command_Kind'Image (Kind (Cmd)));
                  OS_Exit (1);
               end if;
            end;

            Protocol.Send_End_Of_Compilation (S.Channel);

            Close (S.Channel);
         end if;
      end Clean_Up_Remote_Slave;

   begin
      for S of Slaves_Data loop
         Clean_Up_Remote_Slave (S, Get_Name_String (Project.Name));
      end loop;
   end Clean_Up_Remote_Slaves;

   -------------------
   -- Connect_Slave --
   -------------------

   function Connect_Slave
     (S_Data       : Slave_Data;
      Project_Name : String) return Slave
   is
      Address : Sock_Addr_Type;
      Sock    : Socket_Type;
      S       : Slave;
      Status  : Selector_Status;

   begin
      S.Data := S_Data;

      if S.Data.Host = Null_Unbounded_String then
         Write_Line ("A slave must have a name, aborting");
         OS_Exit (1);
      end if;

      Address.Addr := Addresses
        (Get_Host_By_Name (To_String (S.Data.Host)), 1);
      Address.Port := S_Data.Port;

      Create_Socket (Sock);
      Set_Socket_Option (Sock, Socket_Level, (Reuse_Address, True));

      Connect_Socket (Sock, Address, Timeout => 2.0, Status => Status);

      if Status in Expired .. Aborted then
         Write_Line
           ("Cannot connect to slave "
            & To_String (S.Data.Host) & ", aborting");
         OS_Exit (1);
      end if;

      S.Channel := Create (Sock);

      --  Do initial handshake

      Protocol.Send_Context
        (S.Channel, Get_Target, Project_Name,
         (if Build_Env = null then "" else Build_Env.all), S.Data.Sync);

      declare
         Cmd        : constant Command := Get_Command (S.Channel);
         Parameters : constant Argument_List_Access := Args (Cmd);
      begin
         if Kind (Cmd) = OK and then Parameters'Length = 2 then
            S.Max_Processes := Natural'Value (Parameters (1).all);
            S.Root_Dir := To_Unbounded_String (Parameters (2).all);

         elsif Kind (Cmd) = KO then
            Write_Line
              ("Slave OS is not compatible " & To_String (S.Data.Host));
            OS_Exit (1);

         else
            Write_Line ("protocol error: " & Command_Kind'Image (Kind (Cmd)));
            OS_Exit (1);
         end if;
      end;

      return S;
   end Connect_Slave;

   -----------------------
   -- Get_Max_Processes --
   -----------------------

   function Get_Max_Processes return Natural is
   begin
      return Max_Processes;
   end Get_Max_Processes;

   -------------------
   -- Record_Slaves --
   -------------------

   procedure Record_Slaves (Option : String) is

      S : Slice_Set;

      procedure Parse_Build_Slave (V : String);
      --  Parse the build slave V

      -----------------------
      -- Parse_Build_Slave --
      -----------------------

      procedure Parse_Build_Slave (V : String) is
         User : Unbounded_String;
         Host : Unbounded_String;
         Port : Port_Type := Default_Port;
         Sync : Sync_Kind := Protocol.Rsync;
         F    : Natural := V'First;
         I    : Natural := Index (V, "://");
      begin
         --  Check for protocol

         if I /= 0 then
            if V (F .. I - 1) = "rsync" then
               Sync := Protocol.Rsync;
            elsif V (F .. I - 1) = "file" then
               Sync := File;
            else
               Write_Line ("error: unknown protocol in " & V);
               OS_Exit (1);
            end if;

            F := I + 3;
         end if;

         --  Check for user

         I := Index (V, "@", From => F);

         if I /= 0 then
            User := To_Unbounded_String (V (F .. I - 1));

            F := I + 1;
         end if;

         --  Get for port

         I := Index (V, ":", From => F);

         if I = 0 then
            Host := To_Unbounded_String (V (F .. V'Last));

         else
            Host := To_Unbounded_String (V (F .. I - 1));

            declare
               Port_Str : constant String := V (I + 1 .. V'Last);
            begin
               if Strings.Maps.Is_Subset
                 (Maps.To_Set (Port_Str),
                  Maps.Constants.Decimal_Digit_Set)
               then
                  Port := Port_Type'Value (V (I + 1 .. V'Last));
               else
                  Write_Line ("error: invalid port value in " & V);
                  OS_Exit (1);
               end if;
            end;
         end if;

         Slaves_Data.Append (Slave_Data'(Host, User, Port, Sync));
      end Parse_Build_Slave;

   begin
      Create (S, Option, ",");

      for K in 1 .. Slice_Count (S) loop
         Parse_Build_Slave (Slice (S, K));
      end loop;
   end Record_Slaves;

   ----------------------------
   -- Register_Remote_Slaves --
   ----------------------------

   procedure Register_Remote_Slaves
     (Tree    : Project_Tree_Ref;
      Project : Project_Id)
   is

      procedure Register_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String);
      --  Register a slave living on Host for the given project name. User is
      --  used when calling rsync, it is the remote machine user name, if empty
      --  the local user name is used.

      Rsync_Count : Natural := 0;
      --  The number of rsync process started, we need to wait for them to
      --  terminate.

      Start, Stop : Calendar.Time;

      ---------------------------
      -- Register_Remote_Slave --
      ---------------------------

      procedure Register_Remote_Slave
        (S_Data       : Slave_Data;
         Project_Name : String)
      is

         function User_Host return String is
           (if S_Data.User = Null_Unbounded_String
            then To_String (S_Data.Host)
            else To_String (S_Data.User) & '@' & To_String (S_Data.Host));

         S : Slave;
      begin
         S := Connect_Slave (S_Data, Project_Name);

         Set (Slaves_Sockets, Sock (S.Channel));

         --  Sum the Max_Process values

         Max_Processes := Max_Processes + S.Max_Processes;

         if Opt.Verbose_Mode then
            Write_Str ("Register slave " & User_Host & ",");
            Write_Str (Integer'Image (S.Max_Processes));
            Write_Line (" process(es)");
            Write_Line ("  location: " & To_String (S.Root_Dir));
         end if;

         --  Let's double check that Root_Dir and Projet_Name are not empty,
         --  this is a safety check to avoid rsync detroying remote environment
         --  as rsync is using the --delete options.

         if Length (S.Root_Dir) = 0 then
            Write_Line ("error: Root_Dir cannot be empty");
            OS_Exit (1);
         end if;

         if Project_Name = "" then
            Write_Line ("error: Project_Name cannot be empty");
            OS_Exit (1);
         end if;

         if S.Data.Sync = Protocol.Rsync then
            --  Check for rsync tool

            if Rsync = null then
               Write_Line
                 ("error: rsync not found for " & To_String (S.Data.Host));
               OS_Exit (1);
            end if;

            declare
               Args : Argument_List (1 .. 15);
            begin
               --  Archive mode, compression and ignore VCS

               Args (1) := new String'("-arz");

               --  Exclude objects/ali

               Args (2) := new String'("--exclude=*.o");
               Args (3) := new String'("--exclude=*.obj");
               Args (4) := new String'("--exclude=*.ali");
               Args (5) := new String'("--exclude=*.dll");
               Args (6) := new String'("--exclude=*.so");
               Args (7) := new String'("--exclude=*.so.*");
               Args (8) := new String'("--exclude=.git");
               Args (9) := new String'("--exclude=.svn");
               Args (10) := new String'("--exclude=CVS");

               --  Delete remote files not in local directory

               Args (11) := new String'("--delete");
               Args (12) := new String'("--delete-excluded");
               Args (13) := new String'("--copy-links");

               --  Local and remote directory

               Args (14) := new String'(To_String (Root_Dir) & "/");
               Args (15) := new String'
                 (User_Host & ":"
                  & Compose (To_String (S.Root_Dir), Project_Name));

               if Opt.Verbose_Mode then
                  Write_Line ("  synchronize data");
                  Write_Line ("    from: " & Args (Args'Last - 1).all);
                  Write_Line ("    to  : " & Args (Args'Last).all);
               end if;

               S.Rsync_Pid := Non_Blocking_Spawn (Rsync.all, Args);

               Rsync_Count := Rsync_Count + 1;

               for A of Args loop
                  Free (A);
               end loop;
            end;
         end if;

         --  Now that all slave's data is known and set, record it

         S.Sock := To_C (Sock (S.Channel));
         Slaves.Insert (S);
      end Register_Remote_Slave;

      Pcks : Package_Table.Table_Ptr renames Tree.Shared.Packages.Table;
      Pck  : Package_Id := Project.Decl.Packages;

   begin
      Project_Name := To_Unbounded_String (Get_Name_String (Project.Name));

      Root_Dir := To_Unbounded_String
        (Containing_Directory (Get_Name_String (Project.Path.Display_Name)));

      --  Check for Root_Dir attribute

      Look_Remote_Package : while Pck /= No_Package loop
         if Pcks (Pck).Decl /= No_Declarations
           and then Pcks (Pck).Name = Name_Remote
         then
            declare
               Id : Variable_Id := Pcks (Pck).Decl.Attributes;
            begin
               while Id /= No_Variable loop
                  declare
                     V : constant Variable :=
                           Tree.Shared.Variable_Elements.Table (Id);
                  begin
                     if not V.Value.Default then
                        if V.Name = Name_Root_Dir then
                           declare
                              RD : constant String :=
                                     Get_Name_String (V.Value.Value);
                           begin
                              if Is_Absolute_Path (RD) then
                                 Root_Dir := To_Unbounded_String (RD);
                              else
                                 Root_Dir := To_Unbounded_String
                                   (Normalize_Pathname
                                      (To_String (Root_Dir)
                                       & Directory_Separator & RD));
                              end if;

                              if not Exists (To_String (Root_Dir))
                                or else not Is_Directory (To_String (Root_Dir))
                              then
                                 Write_Line
                                   ("error: " & To_String (Root_Dir)
                                    & " is not a directory"
                                    & " or does not exists");
                                 OS_Exit (1);
                              end if;
                           end;
                        end if;
                     end if;
                  end;

                  Id := Tree.Shared.Variable_Elements.Table (Id).Next;
               end loop;
            end;
         end if;

         Pck := Pcks (Pck).Next;
      end loop Look_Remote_Package;

      --  Then registers the build slaves

      Start := Calendar.Clock;

      for S of Slaves_Data loop
         Register_Remote_Slave (S, To_String (Project_Name));
      end loop;

      Wait_Rsync (Rsync_Count);

      Stop := Calendar.Clock;

      if Opt.Verbose_Mode and then Rsync_Count > 0 then
         Write_Str ("  All data synchronized in ");
         Write_Str (Duration'Image (Stop - Start));
         Write_Line (" seconds");
      end if;

      --  We are in remote mode, the initialization was successful, start tasks
      --  now.

      if WR = null then
         WR := new Wait_Remote;
      end if;
   end Register_Remote_Slaves;

   ---------
   -- Run --
   ---------

   function Run
     (Language : String;
      Options  : GNAT.OS_Lib.Argument_List;
      Dep_Name : String := "") return Id
   is
      CWD : constant String := Current_Directory;
      --  CWD is the directory from which the command is run

      RD  : constant String := To_String (Root_Dir);

      S   : Slave := Slaves.Get_Free;
      --  Get a free slave for conducting the compilation

      function Filter_String
        (O : String; Sep : String := WD_Path_Tag) return String;
      --  Make O PATH relative to RD. For option -gnatec and -gnatem makes
      --  the specified filename absolute in the slave environment and send
      --  the file to the slave.

      -------------------
      -- Filter_String --
      -------------------

      function Filter_String
        (O   : String;
         Sep : String := WD_Path_Tag) return String
      is
         Pos : constant Natural := Index (O, RD);
      begin
         if S.Data.Sync = File then
            --  Nothing to translate really, this slave is using a shared
            --  directory to get access to the sources.

            return O;

         else
            if Pos = 0 then
               return O;

            else
               --  Note that we transfer files only when they are under the
               --  project root.

               if O'Length > 8
                 and then O (O'First .. O'First + 7) in "-gnatem=" | "-gnatec="
               then
                  --  Send the corresponding file to the slave
                  declare
                     File_Name : constant String := O (O'First + 8 .. O'Last);
                  begin
                     if Exists (File_Name) then
                        Send_File (S.Channel, File_Name);
                     else
                        Write_Line
                          ("File not found " & File_Name);
                        Write_Line
                          ("Please check that Built_Root is properly set");
                     end if;

                     return O (O'First .. O'First + 7)
                       & Translate_Send (S.Channel, File_Name);
                  end;
               end if;

               return O (O'First .. Pos - 1)
                 & Sep & O (Pos + RD'Length + 1 .. O'Last);
            end if;
         end if;
      end Filter_String;

      Pid : Remote_Id;

   begin
      if S.Data.Sync = File then
         --  Do not filter out CWD as we want the compilation to take place in
         --  the shared directory.

         Send_Exec
           (S.Channel,
            CWD, Language, Options, Dep_Name, Filter_String'Access);

      else
         --  Record the rewrite information for this channel only if we are not
         --  using a shared directory.

         Slaves.Set_Rewrite_WD (S, Path => RD);

         if Compiler_Path /= null then
            Slaves.Set_Rewrite_CD
              (S,
               Path => Containing_Directory
                 (Containing_Directory (Compiler_Path.all)));
         end if;

         Send_Exec
           (S.Channel,
            Filter_String (CWD, Sep => ""), Language, Options, Dep_Name,
            Filter_String'Access);
      end if;

      Remote_Process.Increment;

      --  Wait for the Ack from the remore host, this is set by the Wait_Remote
      --  task.

      Wait_Ack.Get (Pid);

      return Create_Remote (Pid);

   exception
      when E : others =>
         Write_Line ("Unexpected exception: " & Exception_Information (E));
         OS_Exit (1);
   end Run;

   ------------
   -- Slaves --
   ------------

   protected body Slaves is

      --------------------
      -- Change_Current --
      --------------------

      procedure Change_Current (S : in out Slave; Value : Integer) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Pool (Position).Current := Pool (Position).Current + Value;
      end Change_Current;

      -----------
      -- Clear --
      -----------

      procedure Clear is
      begin
         Pool.Clear;
      end Clear;

      -----------------------
      -- Decrement_Current --
      -----------------------

      procedure Decrement_Current (S : in out Slave) is
      begin
         Change_Current (S, -1);
      end Decrement_Current;

      ----------
      -- Find --
      ----------

      function Find (Socket : Integer) return Slave is
         S        : constant Slave := (Sock => Socket, others => <>);
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         if Slave_S.Has_Element (Position) then
            return Slave_S.Element (Position);
         else
            return No_Slave;
         end if;
      end Find;

      function Find (Pid : Process_Id) return Slave is
      begin
         for S of Pool loop
            if S.Rsync_Pid = Pid then
               return S;
            end if;
         end loop;

         return No_Slave;
      end Find;

      --------------
      -- Get_Free --
      --------------

      function Get_Free return Slave is
      begin
         for S of Pool loop
            if S.Current < S.Max_Processes then
               return S;
            end if;
         end loop;

         return No_Slave;
      end Get_Free;

      -----------------------
      -- Increment_Current --
      -----------------------

      procedure Increment_Current (S : in out Slave) is
      begin
         Change_Current (S, 1);
      end Increment_Current;

      ------------
      -- Insert --
      ------------

      procedure Insert (S : Slave) is
      begin
         Pool.Insert (S);
      end Insert;

      -------------
      -- Iterate --
      -------------

      procedure Iterate (Proc : access procedure (S : in out Slave)) is
      begin
         for S of Pool loop
            Proc (S);
         end loop;
      end Iterate;

      --------------------
      -- Set_Rewrite_CD --
      --------------------

      procedure Set_Rewrite_CD (S : in out Slave; Path : String) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Set_Rewrite_CD (Pool (Position).Channel, Path => Path);
         S := Pool (Position);
      end Set_Rewrite_CD;

      --------------------
      -- Set_Rewrite_WD --
      --------------------

      procedure Set_Rewrite_WD (S : in out Slave; Path : String) is
         Position : constant Slave_S.Cursor := Pool.Find (S);
      begin
         Set_Rewrite_WD (Pool (Position).Channel, Path => Path);
         S := Pool (Position);
      end Set_Rewrite_WD;

   end Slaves;

   ------------------------------
   -- Unregister_Remote_Slaves --
   ------------------------------

   procedure Unregister_Remote_Slaves is

      procedure Unregister (S : in out Slave);
      --  Unregister given slave

      Rsync_Count : Natural := 0;
      Start, Stop : Time;

      ----------------
      -- Unregister --
      ----------------

      procedure Unregister (S : in out Slave) is
         function User_Host return String is
           (if S.Data.User = Null_Unbounded_String
            then To_String (S.Data.Host)
            else To_String (S.Data.User) & '@' & To_String (S.Data.Host));
      begin
         Send_End_Of_Compilation (S.Channel);
         Close (S.Channel);

         --  Sync back the object code if needed

         if S.Data.Sync = Protocol.Rsync then
            declare
               Args : Argument_List (1 .. 5);
            begin
               --  Archive mode, compression and ignore VCS

               Args (1) := new String'("-arz");

               Args (2) := new String'("--exclude=output.slave.*");
               Args (3) := new String'("--exclude=GNAT-TEMP*");

               --  Local and remote directory

               Args (4) := new String'
                 (User_Host & ":"
                  & Compose
                    (To_String (S.Root_Dir), To_String (Project_Name))
                  & "/");
               Args (5) := new String'(To_String (Root_Dir));

               if Opt.Verbose_Mode then
                  Write_Line ("  synchronize back data");
                  Write_Line ("    from: " & Args (4).all);
                  Write_Line ("    to  : " & Args (5).all);
               end if;

               S.Rsync_Pid := Non_Blocking_Spawn (Rsync.all, Args);

               Rsync_Count := Rsync_Count + 1;

               for A of Args loop
                  Free (A);
               end loop;
            end;
         end if;
      end Unregister;

   begin
      Start := Clock;

      Slaves.Iterate (Unregister'Access);

      Wait_Rsync (Rsync_Count);

      Stop := Clock;

      if Opt.Verbose_Mode and then Rsync_Count > 0 then
         Write_Str ("  All data synchronized in ");
         Write_Str (Duration'Image (Stop - Start));
         Write_Line (" seconds");
      end if;

      Slaves.Clear;
   end Unregister_Remote_Slaves;

   --------------
   -- Wait_Ack --
   --------------

   protected body Wait_Ack is

      ---------
      -- Set --
      ---------

      procedure Set (Pid : Remote_Id) is
      begin
         Id := Pid;
         Is_Set := True;
      end Set;

      ---------
      -- Get --
      ---------

      entry Get (Pid : out Remote_Id) when Is_Set is
      begin
         Pid := Id;
         Is_Set := False;
      end Get;

   end Wait_Ack;

   -----------------
   -- Wait_Remote --
   -----------------

   task body Wait_Remote is
      use type Slave_S.Cursor;

      Proc         : Id;
      Pid          : Remote_Id;
      Selector     : Selector_Type;
      Status       : Selector_Status;
      R_Set, W_Set : Socket_Set_Type;
      Sock         : Socket_Type;
      S            : Slave;
   begin
      --  In this task we are only interrested by the incoming data, so we do
      --  not wait on incoming ones.

      Sockets.Empty (W_Set);

      Create_Selector (Selector);

      loop
         --  Let's wait for at least some process to monitor

         Remote_Process.Wait_Non_Zero;

         --  Wait for response from all registered slaves

         Copy (Slaves_Sockets, R_Set);

         Check_Selector (Selector, R_Set, W_Set, Status);

         if Status = Completed then
            Get (R_Set, Sock);

            pragma Assert
              (Sock /= No_Socket, "no socket returned by selector");

            S := Slaves.Find (To_C (Sock));

            if S /= No_Slave then
               declare
                  Cmd     : constant Command := Get_Command (S.Channel);
                  Success : Boolean;
               begin
                  --  A display output

                  if Kind (Cmd) = DP then
                     --  Write output to the console

                     Write_Str (To_String (Protocol.Output (Cmd)));

                     Get_Pid (S.Channel, Pid, Success);

                     Proc := Create_Remote (Pid);

                     Remote_Process.Decrement;
                     Slaves.Decrement_Current (S);

                     Result.Add (Proc, Success);

                  --  An acknowledgment of an compilation job

                  elsif Kind (Cmd) = AK then
                     declare
                        Pid : constant Remote_Id :=
                                Remote_Id'Value (Args (Cmd)(1).all);
                     begin
                        Slaves.Increment_Current (S);
                        Wait_Ack.Set (Pid);
                     end;

                  elsif Kind (Cmd) = EC then
                     null;

                  else
                     raise Constraint_Error with "Unexpected command: "
                       & Command_Kind'Image (Kind (Cmd));
                  end if;
               end;
            end if;

         else
            if Opt.Verbose_Mode and then Opt.Verbosity_Level = Opt.High then
               Write_Line
                 ("warning: selector in " & Selector_Status'Image (Status)
                  & " state");
            end if;
         end if;

         Sockets.Empty (R_Set);
      end loop;
   exception
      when E : others =>
         Write_Line (Exception_Information (E));
         OS_Exit (1);
   end Wait_Remote;

   ----------------
   -- Wait_Rsync --
   ----------------

   procedure Wait_Rsync (N : Natural) is
      Pid     : Process_Id;
      Success : Boolean;
      Error   : Boolean := False;
      Slv     : Slave;
   begin
      for K in 1 .. N loop
         Wait_Process (Pid, Success);

         Slv := Slaves.Find (Pid);

         if Success then
            if Opt.Verbose_Mode then
               Write_Line
                 ("  synchronization done for "
                  & To_String (Slv.Data.Host));
            end if;

         else
            Error := True;
            Write_Line ("error: rsync on " & To_String (Slv.Data.Host));
         end if;
      end loop;

      --  If there is any error we cannot continue, just exit now

      if Error then
         OS_Exit (1);
      end if;
   end Wait_Rsync;

end Gprbuild.Compilation.Slave;
