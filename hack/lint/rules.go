// SPDX-License-Identifier: Apache-2.0

//go:build ruleguard

// Package lint holds go-ruleguard rules run by gocritic in golangci-lint.
package lint

import "github.com/quasilyte/go-ruleguard/dsl"

// sqlStart matches a string literal that starts with a SQL statement keyword.
const sqlStart = `(?i)^"\s*(SELECT|INSERT|UPDATE|DELETE|WITH|ALTER|CREATE|DROP|GRANT|REVOKE|COMMENT|TRUNCATE|REASSIGN|SET|RESET|COPY)\b`

// stringBuiltSQL flags SQL text built from untrusted pieces. Identifiers go
// through pgx.Identifier{...}.Sanitize(); values are bind parameters.
func stringBuiltSQL(m dsl.Matcher) {
	m.Match(`fmt.Sprintf($f, $*_)`).
		Where(m["f"].Text.Matches(sqlStart)).
		Report("SQL built with fmt.Sprintf: use pgx.Identifier{...}.Sanitize() for identifiers and bind parameters for values")

	m.Match(`$s + $x`).
		Where(m["s"].Text.Matches(sqlStart) && !m["x"].Const && !m["x"].Text.Matches(`\.Sanitize\(\)$`)).
		Report("SQL built by concatenation: only constants and pgx.Identifier{...}.Sanitize() may be concatenated")
}
