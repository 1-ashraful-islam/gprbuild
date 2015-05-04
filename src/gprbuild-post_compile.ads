------------------------------------------------------------------------------
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                G P R B U I L D . P O S T _ C O M P I L E                 --
--                                                                          --
--                                 S p e c                                  --
--                                                                          --
--         Copyright (C) 2011-2015, Free Software Foundation, Inc.          --
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

package Gprbuild.Post_Compile is

   procedure Run;
   --  Build libraries, if needed, and perform binding, if needed.
   --  This is either for a specific project tree, or for the root project and
   --  all its aggregated projects.

end Gprbuild.Post_Compile;
