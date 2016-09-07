import "hint" HLint.Builtin.All
import "hint" HLint.Default
import "hint" HLint.Dollar

ignore "Use String"

warn = genericToJSON $ prefixedAesonOptions x ==> simpleGenericToJSON
warn = return ==> pure
