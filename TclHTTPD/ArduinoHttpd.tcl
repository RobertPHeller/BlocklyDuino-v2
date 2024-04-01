#*****************************************************************************
#
#  System        : 
#  Module        : 
#  Object Name   : $RCSfile$
#  Revision      : $Revision$
#  Date          : $Date$
#  Author        : $Author$
#  Created By    : Robert Heller
#  Created       : Fri Mar 22 12:20:38 2024
#  Last Modified : <240331.2053>
#
#  Description	
#
#  Notes
#
#  History
#	
#*****************************************************************************
## @copyright
#    Copyright (C) 2024  Robert Heller D/B/A Deepwoods Software
#			51 Locke Hill Road
#			Wendell, MA 01379-9728
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
# @file ArduinoHttpd.tcl
# @author Robert Heller
# @date Fri Mar 22 12:20:38 2024
# 
#
#*****************************************************************************


package require httpd

::clay::define ::docserver::server {
    superclass ::httpd::server
    
    method debug args {
        puts [list DEBUG {*}$args]
    }
    method log args {
        puts [list LOG {*}$args]
    }
    
}
::docserver::server create appmain port 8080

appmain plugin basic_url ::httpd::plugin.dict_dispatch

namespace eval TempFile {
    variable counter 0
    proc mkTempINO {{dir /tmp}} {
        variable counter
        incr counter
        set result [file join $dir [format "%06x" $counter]]
        while {[file exists $result]} {
            incr counter
            set result [file join $dir [format "%06x" $counter]]
        }
        file mkdir $result
        return [file join $result "[file tail $result].ino"]
    }
}

namespace eval Boards {
    
    proc isBoardsFile {path} {
        return [expr {[file tail $path] eq "boards.txt"}]
    }
    proc getBoards {boardsfile} {
        set platform [file join [file dirname $boardsfile] platform.txt]
        if {![file exists $platform]} {return ""}
        set fp [open $platform r]
        while {[gets $fp line] >= 0} {
            if {[regexp {^name=(.*)$} $line => PlatformName] > 0} {
                set result "$PlatformName\n"
                break
            }
        }
        close $fp
        if {![info exists result]} {return ""}
        set pathsplit [file split $boardsfile]
        set hindex [lsearch -exact $pathsplit hardware]
        if {$hindex < 0} {return ""}
        if {[lsearch -exact $pathsplit packages] < 0} {
            set vendor [lindex $pathsplit [expr {$hindex + 1}]]
            set arch   [lindex $pathsplit [expr {$hindex + 2}]]
        } else {
            set vendor [lindex $pathsplit [expr {$hindex - 1}]]
            set arch   [lindex $pathsplit [expr {$hindex + 1}]]
        }
        set fp [open $boardsfile r]
        set currentId {}
        set currentName {}
        set currentCore {}
        set currentMCU {}
        set currentVariant {}
        set lastId {}
        while {[gets $fp line] >= 0} {
            if {[regexp {^[[:space:]]*#} $line] > 0} {continue}
            if {[regexp {^[[:space:]]*$} $line] > 0} {continue}
            if {[regexp {^([^.]+)\.name=(.*)$} $line => id name] > 0} {
                #puts stderr "*** Boards::getBoards: currentId = \"$currentId\""
                #puts stderr "*** Boards::getBoards: id = $id, name = $name"
                if {$currentId ne {}} {
                    append result "${vendor}:${arch}:$currentId $currentCore $currentMCU $currentVariant $currentName\n"
                    set lastId $currentId
                }
                set currentId $id
                set currentName $name
                set corePatttern "^${currentId}\\.build\\.core=(.*)\$"
                set mcuPatttern "^${currentId}\\.build\\.mcu=(.*)\$"
                set variantPatttern "^${currentId}\\.build\\.variant=(.*)\$"
            }
            if {$currentId eq {}} {continue}
            if {[regexp $corePatttern $line => core] > 0} {
                set currentCore $core
            }
            if {[regexp $mcuPatttern $line => mcu] > 0} {
                set currentMCU $mcu
            }
            if {[regexp $variantPatttern $line => variant] > 0} {
                set currentVariant $variant
            }
        }
        if {$currentId ne $lastId} {
            append result "${vendor}:${arch}:$currentId $currentCore $currentMCU $currentVariant $currentName\n"
        }
        close $fp
        return $result
    }
}


appmain uri direct * /* {} {
    set request [my request get REQUEST_URI]
    my log "($request)"
    set length [my request get CONTENT_LENGTH]
    if {[regexp {^/([^/]*)/(.*)$} $request => mode opts] < 1} {
        regexp {^/(.*)$} $request => mode
        my log "($request) mode is $mode"
        set opts {}
    }
    if {$mode in {upload verify}} {
        set prog [my PostData $length]
        my log "($request) prog is \{$prog\}, length is $length" 
        set inofile [::TempFile::mkTempINO]
        set fp [open $inofile w]
        puts -nonewline $fp $prog
        close $fp
        my log "($request) saved as $inofile"
    }
    my reply set Access-Control-Allow-Origin *
    switch $mode {
        upload {
            set cmd [list exec [auto_execok arduino] --upload]
        }
        verify {
            set cmd [list exec [auto_execok arduino] --verify]
        }
        libraries {
            my log "($request) Fetching libraries..."
            if {[catch {exec -ignorestderr [auto_execok arduino] --get-pref sketchbook.path} sketchbook_path]} {
                my log "($request) exec failed: $sketchbook_path"
                my reply set Status 400
                return
            }
            my log "($request) sketchbook_path is $sketchbook_path"
            set libdir [file join $sketchbook_path libraries]
            set libdirs [file join $libdir *]
            set headers [glob -nocomplain [file join $libdirs *.h] [file join $libdirs src *.h]]
            my log "($request) libdir is $libdir"
            my log "($request) libdirs is $libdirs"
            my log "($request) headers are \{$headers\}"
            my reply set "Content-Type" "text/plain;charset=UTF-8"
            foreach h $headers {
                set hfile [file tail $h]
                set library [file dirname $h]
                if {[file tail $library] eq "src"} {set library [file dirname $library]}
                set libname [file tail $library]
                my puts [list $libname $hfile]
            }
            return
        }
        boards {
            my log "($request) Fetching boards"
            if {[catch {exec -ignorestderr [auto_execok arduino] --get-pref runtime.ide.path} runtime_ide_path]} {
                my log "($request) exec failed: $runtime_ide_path"
                my reply set Status 400
                return
            }
            my reply set "Content-Type" "text/plain;charset=UTF-8"                      
            switch -glob $::tcl_platform(os) {
                Darwin {
                    set prefsdir "$::env(HOME)/Library/Arduino15/"
                }
                Windows* {
                    set prefsdir "%LOCALAPPDATA%/Arduino15/"
                }
                default {
                    set prefsdir "$::env(HOME)/.arduino15/"
                }
            }
            package require fileutil::traverse
            set traverser [::fileutil::traverse %AUTO% $runtime_ide_path -filter Boards::isBoardsFile]
            $traverser foreach b {
                my puts [Boards::getBoards $b]
            }
            $traverser destroy
            set traverser [::fileutil::traverse %AUTO% [file join $prefsdir packages]  -filter Boards::isBoardsFile]
            $traverser foreach b {
                my puts [Boards::getBoards $b]
            }
            $traverser destroy
            return
        }
        ports {
            switch -glob $::tcl_platform(os) {
                Darwin {
                    set ports [glob -nocomplain /dev/cu.*]
                }
                Windows* {
                    set ports {}
                    for {set i 1} {$i <= 99} {incr i} {
                        lappend ports [format {COM%d:} $i]
                    }
                }
                Linux {
                    set ports [glob -nocomplain /dev/ttyUSB* /dev/ttyACM*]
                }
            }
            foreach p $ports {
                my puts $p
            }
            return
        }
        default {
            my reply set Status 404
            return
        }
                
    }
    foreach o [split $opts ,] {
        if {[regexp {^([^=]+)=(.*)$} $o => opt value] > 0} {
            if {$value ne ""} {
                lappend cmd "--$opt" $value
            } else {
                lappend cmd "--$opt"
            }
        }
    }
    lappend cmd $inofile "2>@1"
    my log "($request) cmd is \{$cmd\}"
    set status [catch $cmd result]
    if {$status != 0} {
        my reply set Status 400
    }
    my reply set "Content-Type" "text/plain;charset=UTF-8"
    my log "($request) status is $status"
    my log "($request) result is $result"
    my puts $result
}

puts [list LISTENING on [appmain port_listening]]
cron::main

