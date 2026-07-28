rule Suspicious_Reverse_Shell_Strings
{
    meta:
        description = "Flags common reverse-shell one-liner fragments in an executable"
        author = "threadline"
        reference = "starter rule -- tune or replace for your environment"
        severity = "medium"

    strings:
        $s1 = "/bin/sh -i" ascii
        $s2 = "bash -i >& /dev/tcp/" ascii
        $s3 = "nc -e /bin/sh" ascii
        $s4 = "socket.socket(socket.AF_INET" ascii

    condition:
        any of them
}
