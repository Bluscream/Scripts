Dim args, message
Set args = WScript.Arguments
If args.Count > 0 Then
    message = Join(args, " ")
    Dim shell
    Set shell = CreateObject("WScript.Shell")
    shell.Run "banner.exe --message """ & message & """", 0, False
End If
Set shell = Nothing
Set args = Nothing
WScript.Quit