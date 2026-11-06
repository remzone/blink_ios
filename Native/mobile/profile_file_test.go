// SPDX-License-Identifier: GPL-3.0-only
package mobile
import("os";"testing")
func TestPrivateImportFixture(t *testing.T){p:=os.Getenv("BLINK_TEST_IMPORT_FILE");if p==""{t.Skip("private fixture opt-in")};raw,e:=os.ReadFile(p);if e!=nil{t.Fatal("fixture unreadable")};if _,e=ImportProfiles(string(raw));e!=nil{t.Fatal(e)}}
