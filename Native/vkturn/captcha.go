// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Challenge data is memory-only and never part of Status/Events or logs.
type captchaError struct{ fields map[string]interface{} }

func (*captchaError) Error() string { return "captcha_required" }
func (*captchaError) Unwrap() error { return ErrCaptchaRequired }

type captchaChallenge struct {
	ID        string `json:"id"`
	URL       string `json:"url,omitempty"`
	Image     string `json:"image,omitempty"`
	ExpiresAt int64  `json:"expires_at"`
	submitted bool
	result    chan captchaAnswer
}
type captchaAnswer struct{ kind, value string }

func captchaField(fields map[string]interface{}, key string) string {
	switch v := fields[key].(type) {
	case string:
		if len(v) <= 16384 {
			return v
		}
	case float64:
		if v >= 0 && v < 9007199254740992 && v == float64(int64(v)) {
			return strconv.FormatInt(int64(v), 10)
		}
	}
	return ""
}
func safeCaptchaURL(raw string) bool {
	if raw == "" || len(raw) > 16384 {
		return false
	}
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") || u.Fragment != "" {
		return false
	}
	h := strings.ToLower(u.Hostname())
	return h == "vk.com" || h == "vk.ru" || strings.HasSuffix(h, ".vk.com") || strings.HasSuffix(h, ".vk.ru")
}
func (c *Client) CaptchaJSON() string {
	c.captchaMu.Lock()
	defer c.captchaMu.Unlock()
	if c.challenge == nil {
		return "{}"
	}
	raw, _ := json.Marshal(c.challenge)
	return string(raw)
}

// SubmitCaptcha accepts one result only, bound to a random challenge ID and deadline.
func (c *Client) SubmitCaptcha(id, kind, value string) bool {
	if (kind != "key" && kind != "token") || len(value) == 0 || len(value) > 16384 || strings.ContainsAny(value, "\r\n\x00") {
		return false
	}
	c.captchaMu.Lock()
	defer c.captchaMu.Unlock()
	p := c.challenge
	if p == nil || p.submitted || p.ID != id || time.Now().Unix() >= p.ExpiresAt {
		return false
	}
	if kind == "key" && p.Image == "" || kind == "token" && p.URL == "" {
		return false
	}
	select {
	case p.result <- captchaAnswer{kind, value}:
		p.submitted = true
		diagnosticStage("native.vk.captcha_submitted", 0)
		return true
	default:
		return false
	}
}
func (c *Client) awaitCaptcha(ctx context.Context, fields map[string]interface{}) (captchaAnswer, error) {
	raw, image := captchaField(fields, "redirect_uri"), captchaField(fields, "captcha_img")
	if !safeCaptchaURL(raw) {
		raw = ""
	}
	if !safeCaptchaURL(image) {
		image = ""
	}
	if raw == "" && (image == "" || captchaField(fields, "captcha_sid") == "") {
		return captchaAnswer{}, ErrCaptchaRequired
	}
	p := &captchaChallenge{ID: uuid.NewString(), URL: raw, Image: image, ExpiresAt: time.Now().Add(5 * time.Minute).Unix(), result: make(chan captchaAnswer, 1)}
	c.captchaMu.Lock()
	c.challenge = p
	c.captchaMu.Unlock()
	diagnosticStage("native.vk.captcha_required", 0)
	c.setState("captcha_required")
	defer func() {
		c.captchaMu.Lock()
		if c.challenge == p {
			c.challenge = nil
		}
		c.captchaMu.Unlock()
	}()
	timer := time.NewTimer(5 * time.Minute)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return captchaAnswer{}, ctx.Err()
	case <-timer.C:
		return captchaAnswer{}, ErrCaptchaRequired
	case answer := <-p.result:
		c.setState("connecting")
		return answer, nil
	}
}

// Retry the exact request through its existing HTTP client/cookie jar after human verification.
func (c *Client) captchaRequest(ctx context.Context, data, endpoint string, request func(string, string) (map[string]interface{}, error)) (map[string]interface{}, error) {
	for attempt := 0; attempt < 3; attempt++ {
		response, err := request(data, endpoint)
		var challenge *captchaError
		if !c.config.ManualCaptcha || !errors.As(err, &challenge) {
			return response, err
		}
		answer, err := c.awaitCaptcha(ctx, challenge.fields)
		if err != nil {
			return nil, err
		}
		form, err := url.ParseQuery(data)
		if err != nil {
			return nil, ErrCaptchaRequired
		}
		form.Del("success_token")
		form.Del("captcha_key")
		if answer.kind == "key" {
			form.Set("captcha_key", answer.value)
		} else {
			form.Set("success_token", answer.value)
			form.Set("captcha_key", "")
		}
		for _, k := range []string{"captcha_sid", "captcha_ts", "captcha_attempt"} {
			if v := captchaField(challenge.fields, k); v != "" {
				form.Set(k, v)
			}
		}
		if form.Get("captcha_attempt") == "0" {
			form.Set("captcha_attempt", "1")
		}
		data = form.Encode()
	}
	return nil, ErrCaptchaRequired
}
