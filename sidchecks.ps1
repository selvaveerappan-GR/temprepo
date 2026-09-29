dsregcmd /status

whoami /user
whoami /groups

Get-LocalGroupMember -SID 'S-1-5-32-544' |
    Format-Table Name, SID, PrincipalSource -AutoSize
