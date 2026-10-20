"""Import public puzzle facts from a saved HTML table; never execute site scripts.
Usage: python3 scripts/import_btc_puzzles.py INPUT_HTML CAPTURED_AT_UTC
"""
import hashlib
import datetime
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

class PuzzleTableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = None
        self.in_code = False
        self.code = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'tr' and 'data-puzzle' in attrs:
            assert attrs.get('data-status') in ('solved', 'unsolved'), 'Unknown puzzle status'
            self.row = {'id': int(attrs['data-puzzle']), 'solved': attrs['data-status'] == 'solved'}
        if tag == 'code' and self.row is not None:
            self.in_code = True
            self.code = []

    def handle_data(self, data):
        if self.in_code:
            self.code.append(data)

    def handle_endtag(self, tag):
        if tag == 'code' and self.in_code:
            address = ''.join(self.code).strip()
            if re.fullmatch(r'1[1-9A-HJ-NP-Za-km-z]{25,34}', address):
                self.row['address'] = address
            self.in_code = False
        if tag == 'tr' and self.row is not None:
            self.rows.append(self.row)
            self.row = None

if __name__ == '__main__':
    datetime.datetime.strptime(sys.argv[2], '%Y-%m-%dT%H:%M:%SZ')
    html = Path(sys.argv[1]).read_bytes()
    parser = PuzzleTableParser()
    parser.feed(html.decode('utf-8'))
    rows = sorted(parser.rows, key=lambda row: row['id'])
    assert [row['id'] for row in rows] == list(range(1, 161)), 'Expected all 160 unique puzzle numbers'
    assert all('address' in row for row in rows), 'Missing address'
    assert len({row['address'] for row in rows}) == 160, 'Duplicate address'
    document = {
        'sourceURL': 'https://privatekeyfinder.io/bitcoin-puzzle',
        'capturedAt': sys.argv[2],
        'sourceSHA256': hashlib.sha256(html).hexdigest(),
        'puzzles': rows,
    }
    output = Path(__file__).resolve().parents[1] / 'AllKeyUI/Resources/btc-puzzles.json'
    output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(rows)} puzzles, {sum(row["solved"] for row in rows)} solved in source snapshot -> {output}')
