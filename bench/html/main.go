// HTML rendering: a 2000-row product table rendered 400 times with strings.Builder.
// Hand-written baseline; bench/html/main.c and bench/html_hand/main.or print the same bytes.
package main

import (
	"fmt"
	"strconv"
	"strings"
)

const rows = 2000
const pages = 400

func escape(sb *strings.Builder, s string) {
	start := 0
	for i := 0; i < len(s); i++ {
		var r string
		switch s[i] {
		case '&':
			r = "&amp;"
		case '<':
			r = "&lt;"
		case '>':
			r = "&gt;"
		case '"':
			r = "&quot;"
		case '\'':
			r = "&#39;"
		default:
			continue
		}
		sb.WriteString(s[start:i])
		sb.WriteString(r)
		start = i + 1
	}
	sb.WriteString(s[start:])
}

func safeUrl(u string) string {
	for i := 0; i < len(u); i++ {
		c := u[i]
		if c == '/' || c == '?' || c == '#' {
			return u
		}
		if c == ':' {
			switch strings.ToLower(u[:i]) {
			case "http", "https", "mailto", "tel":
				return u
			}
			return "about:invalid#orin-unsafe-url"
		}
	}
	return u
}

var names, urls [rows]string
var prices [rows]int

func render(sb *strings.Builder) {
	sb.WriteString("<html><head><title>Products</title></head><body><h1 class=\"title\">Catalog &amp; Prices</h1><table class=\"products\">")
	for i := 0; i < rows; i++ {
		sb.WriteString("<tr data-id=\"")
		sb.WriteString(strconv.Itoa(i))
		if i%2 == 0 {
			sb.WriteString("\" class=\"row even\">")
		} else {
			sb.WriteString("\" class=\"row odd\">")
		}
		sb.WriteString("<td class=\"name\">")
		escape(sb, names[i])
		sb.WriteString("</td><td class=\"price\">")
		sb.WriteString(strconv.Itoa(prices[i]))
		sb.WriteString("</td><td><a href=\"")
		escape(sb, safeUrl(urls[i]))
		sb.WriteString("\">details</a></td><td><input type=\"checkbox\"")
		if i%3 == 0 {
			sb.WriteString(" disabled")
		}
		sb.WriteString("></td></tr>")
	}
	sb.WriteString("</table><p>" + strconv.Itoa(rows) + " items</p></body></html>")
}

func main() {
	for i := 0; i < rows; i++ {
		n := "Item " + strconv.Itoa(i)
		if i%7 == 0 {
			n += " <b>&\"sale\"</b> it's"
		}
		names[i] = n
		if i%11 == 0 {
			urls[i] = "javascript:alert(" + strconv.Itoa(i) + ")"
		} else {
			urls[i] = "/item/" + strconv.Itoa(i)
		}
		prices[i] = (i * 37) % 1000
	}
	total := 0
	var last string
	for p := 0; p < pages; p++ {
		var sb strings.Builder
		render(&sb)
		last = sb.String()
		total += len(last)
	}
	h := 0
	for i := 0; i < len(last); i++ {
		h = (h*31 + int(last[i])) % 1000000007
	}
	fmt.Printf("bytes %d\nhash %d\nhead %s\n", total, h, last[:120])
}
