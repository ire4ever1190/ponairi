import ../data
var db: DbConn

discard db.find(everybody.orderBy([nullsFirst name])) #[Error
                                              ^ name is not nullable]#
