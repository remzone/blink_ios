// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"errors"
	"github.com/remzone/blink_ios/native/resources"
)

// PrepareAssets installs the pinned data into the platform's private directory.
// Call once before importing JSON profiles or starting an engine.
func PrepareAssets(directory string) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active != nil {
		return errors.New("prepare assets before connecting")
	}
	return resources.Prepare(directory)
}
