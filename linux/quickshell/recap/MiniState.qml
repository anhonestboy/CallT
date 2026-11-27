pragma Singleton
import Quickshell

// Stato della pillola, condiviso dalle finestre dei vari monitor.
Singleton {
    property bool shown: false
    property string screenName: ""  // monitor con il fuoco quando è stata chiamata
}
