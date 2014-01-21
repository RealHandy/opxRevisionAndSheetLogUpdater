$debug_level = 0
def dbgp( str, level = 1 )
    # If in RevitRubyShell, debug with puts. If in Revit macro, use dialog boxes.
    if $is_revitrubyshell
        $debug_level >= level ? puts( str ) : nil
    else
        $debug_level >= level ? TaskDialog.Show("Macro", str) : nil
    end
end
def report_error( str )
    dbgp( str, -1 )
end
