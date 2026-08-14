import urllib.request
import json

url = 'https://codeberg.org/api/v1/repos/Freeyourgadget/Gadgetbridge/git/trees/master?recursive=1'
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    response = urllib.request.urlopen(req)
    data = json.loads(response.read().decode('utf-8'))
    for item in data.get('tree', []):
        if 'FetchActivityOperation' in item['path']:
            print('Found:', item['path'])
except Exception as e:
    print('Error:', e)
