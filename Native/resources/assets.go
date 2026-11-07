// SPDX-License-Identifier: GPL-3.0-only
package resources

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"io"
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
		// Streaming avoids allocating both complete embedded and on-disk files in the
		// memory-constrained packet tunnel process (previously >12 MiB transiently).
		source, err := data.Open(name)
		if err != nil {
			return err
		}
		expected := sha256.New()
		_, err = io.Copy(expected, source)
		source.Close()
		if err != nil {
			return err
		}
		path := filepath.Join(directory, name)
		same := false
		if old, e := os.Open(path); e == nil {
			actual := sha256.New()
			_, e = io.Copy(actual, old)
			old.Close()
			same = e == nil && bytes.Equal(expected.Sum(nil), actual.Sum(nil))
		}
		if same {
			continue
		}
		source, err = data.Open(name)
		if err != nil {
			return err
		}
		temporary := path + ".tmp"
		out, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			source.Close()
			return err
		}
		_, copyErr := io.Copy(out, source)
		source.Close()
		closeErr := out.Close()
		if copyErr != nil {
			os.Remove(temporary)
			return copyErr
		}
		if closeErr != nil {
			os.Remove(temporary)
			return closeErr
		}
		if err = os.Rename(temporary, path); err != nil {
			return err
		}
	}
	return os.Setenv("XRAY_LOCATION_ASSET", directory)
}
