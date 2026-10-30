// SPDX-FileCopyrightText: 2023 The Pion community <https://pion.ly>
// SPDX-License-Identifier: MIT
// Adapted from cacggghp/vk-turn-proxy e8a96967dc66f3dbd631596ea6a8b9fe03f9be69.
// Repository distribution includes GPL-3.0; see LICENSE and UPSTREAM.md.

package vkturn

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
	"github.com/google/uuid"
	"io"
	neturl "net/url"
	"strings"
	"time"
)

type Profile struct{ UserAgent, SecChUa, SecChUaMobile, SecChUaPlatform string }

func applyBrowserProfileFhttp(req *fhttp.Request, profile Profile) {
	req.Header.Set("User-Agent", profile.UserAgent)
	req.Header.Set("sec-ch-ua", profile.SecChUa)
	req.Header.Set("sec-ch-ua-mobile", profile.SecChUaMobile)
	req.Header.Set("sec-ch-ua-platform", profile.SecChUaPlatform)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("DNT", "1")
}

type VKCredentials struct {
	ClientID     string
	ClientSecret string
}

var vkCredentialsList = []VKCredentials{
	{ClientID: "6287487", ClientSecret: "QbYic1K3lEV5kTGiqlq2"},  // VK_WEB_APP_ID
	{ClientID: "7879029", ClientSecret: "aR5NKGmm03GYrCiNKsaw"},  // VK_MVK_APP_ID
	{ClientID: "52461373", ClientSecret: "o557NLIkAErNhakXrQ7A"}, // VK_WEB_VKVIDEO_APP_ID
	{ClientID: "52649896", ClientSecret: "WStp4ihWG4l3nmXZgIbC"}, // VK_MVK_VKVIDEO_APP_ID
	{ClientID: "51781872", ClientSecret: "IjjCNl4L4Tf5QZEXIHKK"}, // VK_ID_AUTH_APP
}

func (c *Client) tokenChain(ctx context.Context, link string, creds VKCredentials, jar tlsclient.CookieJar) (string, string, string, error) {
	profile := Profile{
		UserAgent:       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
		SecChUa:         `"Not(A:Brand";v="99", "Google Chrome";v="146", "Chromium";v="146"`,
		SecChUaMobile:   "?0",
		SecChUaPlatform: `"Windows"`,
	}

	client, err := tlsclient.NewHttpClient(tlsclient.NewNoopLogger(),
		tlsclient.WithTimeoutSeconds(20),
		tlsclient.WithClientProfile(profiles.Chrome_146),
		tlsclient.WithCookieJar(jar),
		tlsclient.WithNotFollowRedirects(),
		tlsclient.WithDialer(*c.dialer),
		tlsclient.WithDisableHttp3(), // QUIC creates its own UDP sockets outside net.Dialer Control.
	)
	if err != nil {
		return "", "", "", fmt.Errorf("failed to initialize tls_client: %w", err)
	}

	defer client.CloseIdleConnections()

	doRequest := func(data string, url string) (resp map[string]interface{}, err error) {
		parsedURL, err := neturl.Parse(url)
		if err != nil {
			return nil, fmt.Errorf("parse request URL: %w", err)
		}
		domain := parsedURL.Hostname()

		req, err := fhttp.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer([]byte(data)))
		if err != nil {
			return nil, err
		}

		req.Host = domain
		applyBrowserProfileFhttp(req, profile)
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Accept", "*/*")
		req.Header.Set("Origin", "https://vk.ru")
		req.Header.Set("Referer", "https://vk.ru/")
		req.Header.Set("Sec-Fetch-Site", "same-site")
		req.Header.Set("Sec-Fetch-Mode", "cors")
		req.Header.Set("Sec-Fetch-Dest", "empty")
		req.Header.Set("Priority", "u=1, i")

		httpResp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer httpResp.Body.Close()
		if httpResp.StatusCode != 200 {
			return nil, errors.New("VK HTTP request rejected")
		}

		body, err := readBounded(httpResp.Body)
		if err != nil {
			return nil, err
		}

		return parseVKResponse(body)
	}

	return tokenChainRequests(ctx, link, creds, doRequest)
}

// Isolated request sequence permits deterministic protocol fixtures without VK.
func tokenChainRequests(ctx context.Context, link string, creds VKCredentials, doRequest func(string, string) (map[string]interface{}, error)) (string, string, string, error) {
	escapedName := neturl.QueryEscape("Blink")
	// Token 1
	data := fmt.Sprintf("client_id=%s&token_type=messages&client_secret=%s&version=1&app_id=%s", creds.ClientID, creds.ClientSecret, creds.ClientID)
	resp, err := doRequest(data, "https://login.vk.ru/?act=get_anonym_token")
	if err != nil {
		return "", "", "", err
	}
	dataMap, ok := resp["data"].(map[string]interface{})
	if !ok {
		return "", "", "", fmt.Errorf("unexpected anon token response")
	}
	token1, ok := dataMap["access_token"].(string)
	if !ok {
		return "", "", "", fmt.Errorf("missing access_token in response")
	}

	if err := pause(ctx, 150*time.Millisecond); err != nil {
		return "", "", "", err
	}

	// Token 1 -> getCallPreview
	data = fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&fields=photo_200&access_token=%s", link, neturl.QueryEscape(token1))
	_, err = doRequest(data, "https://api.vk.ru/method/calls.getCallPreview?v=5.275&client_id="+creds.ClientID)
	if errors.Is(err, ErrCaptchaRequired) {
		return "", "", "", err
	}

	if err := pause(ctx, 400*time.Millisecond); err != nil {
		return "", "", "", err
	}

	// Token 2
	data = fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&name=%s&access_token=%s", link, escapedName, neturl.QueryEscape(token1))
	urlAddr := fmt.Sprintf("https://api.vk.ru/method/calls.getAnonymousToken?v=5.275&client_id=%s", creds.ClientID)

	var token2 string
	for {
		resp, err = doRequest(data, urlAddr)
		if err != nil {
			return "", "", "", err
		}

		if errObj, hasErr := resp["error"].(map[string]interface{}); hasErr {
			if code, _ := errObj["error_code"].(float64); code == 14 {
				return "", "", "", ErrCaptchaRequired
			}

			return "", "", "", fmt.Errorf("VK API error")
		}

		respMap, okLoop := resp["response"].(map[string]interface{})
		if !okLoop {
			return "", "", "", fmt.Errorf("unexpected getAnonymousToken response")
		}
		token2, okLoop = respMap["token"].(string)
		if !okLoop {
			return "", "", "", fmt.Errorf("missing token in response")
		}
		break
	}

	if err := pause(ctx, 150*time.Millisecond); err != nil {
		return "", "", "", err
	}

	// Token 3
	sessionData := fmt.Sprintf(`{"version":2,"device_id":"%s","client_version":1.1,"client_type":"SDK_JS"}`, uuid.New())
	data = fmt.Sprintf("session_data=%s&method=auth.anonymLogin&format=JSON&application_key=CGMMEJLGDIHBABABA", neturl.QueryEscape(sessionData))
	resp, err = doRequest(data, "https://calls.okcdn.ru/fb.do")
	if err != nil {
		return "", "", "", err
	}
	token3, ok := resp["session_key"].(string)
	if !ok {
		return "", "", "", fmt.Errorf("missing session_key in response")
	}

	if err := pause(ctx, 150*time.Millisecond); err != nil {
		return "", "", "", err
	}

	// Token 4 -> TURN Creds
	data = fmt.Sprintf("joinLink=%s&isVideo=false&protocolVersion=5&capabilities=2F7F&anonymToken=%s&method=vchat.joinConversationByLink&format=JSON&application_key=CGMMEJLGDIHBABABA&session_key=%s", link, neturl.QueryEscape(token2), neturl.QueryEscape(token3))
	resp, err = doRequest(data, "https://calls.okcdn.ru/fb.do")
	if err != nil {
		return "", "", "", err
	}

	tsRaw, ok := resp["turn_server"].(map[string]interface{})
	if !ok {
		return "", "", "", fmt.Errorf("missing turn_server in response")
	}
	user, ok := tsRaw["username"].(string)
	if !ok {
		return "", "", "", fmt.Errorf("missing username in turn_server")
	}
	pass, ok := tsRaw["credential"].(string)
	if !ok {
		return "", "", "", fmt.Errorf("missing credential in turn_server")
	}
	urlsRaw, ok := tsRaw["urls"].([]interface{})
	if !ok || len(urlsRaw) == 0 {
		return "", "", "", fmt.Errorf("missing or empty urls in turn_server")
	}
	urlStr, ok := urlsRaw[0].(string)
	if !ok {
		return "", "", "", fmt.Errorf("turn server url is not a string")
	}

	clean := strings.Split(urlStr, "?")[0]
	address := strings.TrimPrefix(strings.TrimPrefix(clean, "turn:"), "turns:")

	return user, pass, address, nil
}

func readBounded(r io.Reader) ([]byte, error) {
	b, e := io.ReadAll(io.LimitReader(r, 1024*1024+1))
	if e != nil {
		return nil, e
	}
	if len(b) > 1024*1024 {
		return nil, errors.New("VK response exceeds limit")
	}
	return b, nil
}

// Credentials are per-client, never global or persisted. Serialization prevents
// parallel anonymous-token chains from triggering upstream request throttling.
func (c *Client) credentials(ctx context.Context) (string, string, string, error) {
	select {
	case <-ctx.Done():
		return "", "", "", ctx.Err()
	case <-c.authGate:
	}
	defer func() { c.authGate <- struct{}{} }()
	if time.Now().Before(c.credsUntil) {
		return c.username, c.password, c.turnAddress, nil
	}
	if err := pause(ctx, time.Until(c.nextAuth)); err != nil {
		return "", "", "", err
	}
	defer func() { c.nextAuth = time.Now().Add(5 * time.Second) }()
	jar := tlsclient.NewCookieJar()
	for _, app := range vkCredentialsList {
		u, p, a, e := c.tokenChain(ctx, c.link, app, jar)
		if errors.Is(e, ErrCaptchaRequired) {
			return "", "", "", e
		}
		if ctx.Err() != nil {
			return "", "", "", ctx.Err()
		}
		if e == nil {
			c.username, c.password, c.turnAddress = u, p, a
			c.credsUntil = time.Now().Add(9 * time.Minute)
			return u, p, a, nil
		}
	}
	return "", "", "", errors.New("VK credential request failed")
}

func parseVKResponse(body []byte) (map[string]interface{}, error) {
	var response map[string]interface{}
	if json.Unmarshal(body, &response) != nil {
		return nil, errors.New("invalid VK response")
	}
	if obj, ok := response["error"].(map[string]interface{}); ok {
		if code, _ := obj["error_code"].(float64); code == 14 {
			return nil, ErrCaptchaRequired
		}
		if _, ok := obj["captcha_sid"]; ok {
			return nil, ErrCaptchaRequired
		}
	}
	return response, nil
}
