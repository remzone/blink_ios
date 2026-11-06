// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func waitChallenge(t *testing.T, c *Client) map[string]interface{} {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var p map[string]interface{}
		_ = json.Unmarshal([]byte(c.CaptchaJSON()), &p)
		if p["id"] != nil {
			return p
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("challenge not published")
	return nil
}
func TestManualCaptchaResumesSameRequestWithoutSID(t *testing.T) {
	c := &Client{config: Config{ManualCaptcha: true}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int32
	done := make(chan error, 1)
	go func() {
		_, e := c.captchaRequest(ctx, "access_token=private_fixture&name=Blink", "https://api.vk.ru/method/fixture", func(data, endpoint string) (map[string]interface{}, error) {
			if calls.Add(1) == 1 {
				return parseVKResponse([]byte(`{"error":{"error_code":14,"redirect_uri":"https://api.vk.ru/captcha?session_token=fixture"}}`))
			}
			form, e := url.ParseQuery(data)
			if e != nil || form.Get("access_token") != "private_fixture" || form.Get("name") != "Blink" || form.Get("success_token") != "human_fixture" || endpoint != "https://api.vk.ru/method/fixture" {
				return nil, errors.New("request context lost")
			}
			return map[string]interface{}{"response": "ok"}, nil
		})
		done <- e
	}()
	p := waitChallenge(t, c)
	id := p["id"].(string)
	if c.SubmitCaptcha("stale", "token", "human_fixture") {
		t.Fatal("stale challenge accepted")
	}
	if c.SubmitCaptcha(id, "key", "wrong kind") {
		t.Fatal("wrong result type accepted")
	}
	if !c.SubmitCaptcha(id, "token", "human_fixture") {
		t.Fatal("valid result rejected")
	}
	if c.SubmitCaptcha(id, "token", "replay") {
		t.Fatal("replay accepted")
	}
	if e := <-done; e != nil {
		t.Fatal(e)
	}
	if calls.Load() != 2 || c.CaptchaJSON() != "{}" {
		t.Fatal("wrong retry or uncleared challenge")
	}
}
func TestManualLegacyKeyAndCloseCancellation(t *testing.T) {
	for _, answer := range []bool{true, false} {
		c := &Client{config: Config{ManualCaptcha: true}}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			a, e := c.awaitCaptcha(ctx, map[string]interface{}{"captcha_sid": "123", "captcha_img": "https://vk.com/captcha.php?sid=fixture"})
			if e == nil && (a.kind != "key" || a.value != "code") {
				e = errors.New("wrong key")
			}
			done <- e
		}()
		p := waitChallenge(t, c)
		if answer {
			if !c.SubmitCaptcha(p["id"].(string), "key", "code") {
				t.Fatal("key rejected")
			}
		} else {
			cancel()
		}
		select {
		case e := <-done:
			if answer && e != nil || !answer && !errors.Is(e, context.Canceled) {
				t.Fatal(e)
			}
		case <-time.After(time.Second):
			t.Fatal("cancellation blocked")
		}
		cancel()
		if c.CaptchaJSON() != "{}" {
			t.Fatal("challenge retained")
		}
	}
}
func TestCaptchaTrustAndRedaction(t *testing.T) {
	for _, raw := range []string{"http://vk.ru/x", "https://vk.ru.evil.example/x", "https://evilvk.ru/x", "https://user@vk.ru/x", "https://vk.ru:444/x", "file:///tmp/x", "https://vk.ru/x#frag"} {
		if safeCaptchaURL(raw) {
			t.Fatal("untrusted URL", raw)
		}
	}
	c := &Client{}
	_, e := c.awaitCaptcha(context.Background(), map[string]interface{}{"redirect_uri": "https://evil.example/x"})
	if !errors.Is(e, ErrCaptchaRequired) || c.CaptchaJSON() != "{}" {
		t.Fatal("unsafe challenge exposed")
	}
	_, e = parseVKResponse([]byte(`{"error":{"error_code":14,"redirect_uri":"private-fixture"}}`))
	if e.Error() != "captcha_required" || strings.Contains(e.Error(), "fixture") {
		t.Fatal("challenge leaked into public error")
	}
}
