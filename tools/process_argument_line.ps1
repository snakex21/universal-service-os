function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $index = 0
    while ($index -lt $Value.Length) {
        $backslashes = 0
        while ($index -lt $Value.Length -and $Value[$index] -eq '\') {
            $backslashes++
            $index++
        }

        if ($index -ge $Value.Length) {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            break
        }

        if ($Value[$index] -eq '"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
        } else {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * $backslashes)) }
            [void]$builder.Append($Value[$index])
        }
        $index++
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-NativeArgumentLine([object[]]$Arguments) {
    $quoted = foreach ($argument in $Arguments) {
        ConvertTo-NativeArgument ([string]$argument)
    }
    return ($quoted -join ' ')
}
