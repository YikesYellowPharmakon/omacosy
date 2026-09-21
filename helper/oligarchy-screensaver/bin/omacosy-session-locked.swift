import ApplicationServices
import Foundation

let dict = CGSessionCopyCurrentDictionary() as NSDictionary?
print((dict?["CGSSessionScreenIsLocked"] as? Bool) == true ? 1 : 0)
