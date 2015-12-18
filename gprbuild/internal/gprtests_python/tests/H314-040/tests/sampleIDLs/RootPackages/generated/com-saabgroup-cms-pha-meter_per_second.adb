--  ============================================================================
--
--         WARNING: THIS FILE IS AUTO-GENERATED. DO NOT MODIFY.
--
--  This file was generated from com_saabgroup_cms_pha.idl using "rtiddsgen".
--  The rtiddsgen tool is part of the RTI Data Distribution Service distribution.
--  For more information, type 'rtiddsgen -help' at a command shell
--  or consult the RTI Data Distribution Service manual.
--
--  ============================================================================

with RTI;
package body com.saabgroup.cms.pha.METER_PER_SECOND is
   use type RTI.Bool;
   procedure Initialize
     (This              : in out METER_PER_SECOND) is
      function Internal
        (This : not null access METER_PER_SECOND)
         return RTI.Bool;
      pragma Import (C, Internal, "com_saabgroup_cms_pha_METER_PER_SECOND_initialize_ex");
   begin
      if not Internal (This'Unrestricted_Access) then
         raise DDS.ERROR with "unable to initialize";
      end if;
   end Initialize;

   procedure Finalize
     (This            : in out METER_PER_SECOND) is
      function Internal
        (This : access METER_PER_SECOND)
         return RTI.Bool;
      pragma Import (C, Internal, "com_saabgroup_cms_pha_METER_PER_SECOND_finalize_ex");
   begin
      if not Internal (This'Unrestricted_Access) then
         raise DDS.ERROR with "unable to finalize";
      end if;
   end Finalize;

   procedure Copy
     (Dst : in out METER_PER_SECOND;
      Src : in METER_PER_SECOND) is
      function Internal
        (Dst : not null access METER_PER_SECOND;
         Src : not null access METER_PER_SECOND)
         return RTI.Bool;
      pragma Import (C, Internal, "com_saabgroup_cms_pha_METER_PER_SECOND_copy");
   begin
      if not Internal (Dst'Unrestricted_Access, Src'Unrestricted_Access) then
         raise DDS.ERROR with "unable to copy";
      end if;
   end Copy;

end com.saabgroup.cms.pha.METER_PER_SECOND;