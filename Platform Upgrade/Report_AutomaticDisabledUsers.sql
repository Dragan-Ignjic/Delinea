/*
    Report: Users disabled by Automatic AD User Disabling
    Purpose: Pre-migration review of accounts that Secret Server automatically
             disabled because they were disabled or removed in Active Directory.
    Scope:   Read-only. Safe to run against production.
*/
SELECT [UserId]
      ,[UserName]
      ,[DisplayName]
      ,[LastLogin]
      ,[Created]
      ,[Enabled]
      ,[EmailAddress]
  FROM dbo.tbUser
 WHERE [DisabledByAutomaticADUserDisabling] = 1
 AND Enabled = 0
 ORDER BY [UserName]
