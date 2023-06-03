discard """
cmd: "nim check $file"
"""
import ../data
var db: DbConn

discard db.find(everybody.orderBy([nullsFirst name])) #[tt.Error
                                              ^ name is not nullable]#
