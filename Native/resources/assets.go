// SPDX-License-Identifier: GPL-3.0-only
package resources

import (
	"bytes"
	"embed"
	"os"
	"path/filepath"
)

// Data is extracted from the pinned official Xray distribution. See UPSTREAM.md.
//
//go:embed geoip.dat geosite.dat
var data embed.FS

func Prepare(directory string) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		b, err := data.ReadFile(name)
		if err != nil {
			return err
		}
		path := filepath.Join(directory, name)
		old, _ := os.ReadFile(path)
		if !bytes.Equal(old, b) {
			temporary := path + ".tmp"
			if err = os.WriteFile(temporary, b, 0600); err != nil {
				return err
			}
			if err = os.Rename(temporary, path); err != nil {
				return err
			}
		}
	}
	return os.Setenv("XRAY_LOCATION_ASSET", directory)
}
