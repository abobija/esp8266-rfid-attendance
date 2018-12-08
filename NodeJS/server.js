/*
 ******************************************************
 *
 * Title: RFID Based Attendance System (WiFi ESP8266)
 * Author: Alija Bobija
 *
 * https://github.com/abobija/esp8266-rfid-attendance
 *
 *****************************************************
*/

var http = require('http');
var fs   = require('fs');
const WebSocket = require('ws');
const wss = new WebSocket.Server({ port: 8080 });

var TAGS_FILE_PATH = 'tags.json';

var notAuthorized = function(res) {
	res.statusCode = 401;
	res.statusMessage = 'Unauthorized';
	return res.end('Unauthorized');
};

var notRegistered = function(res) {
	res.statusCode = 404;
	res.statusMessage = 'Not found';
	return res.end('RfidTag is not registered');
};

var getTag = function(val) {
	var authorizedTags = JSON.parse(fs.readFileSync(TAGS_FILE_PATH));

	for(var i in authorizedTags) {
		if(authorizedTags[i].Value.trim() == val.trim()) {
			return authorizedTags[i];
		}
	}

	return null;
};

var lastEntryForTag = function(entries, authTag) {
	for(var i = entries.length - 1; i >= 0; i--) {
		if(entries[i].TagId == authTag.Id) {
			return entries[i];
		}
	}

	return null;
};

wss.on('connection', function connection(ws) {
        ws.on('message', function incoming(message) {
                //console.log('received: %s', message);

		var request = JSON.parse(message);

		var response = {
			Success: true,
			Context: {
				Action: request.Action
			}
		};

		switch(request.Action) {
			case 'GetTags':
				var entries = JSON.parse(fs.readFileSync('entries.json'));
                                var authorizedTags = JSON.parse(fs.readFileSync(TAGS_FILE_PATH));

                                for(var i in authorizedTags) {
                                	var lastEntry = lastEntryForTag(entries, authorizedTags[i]);

                                        if(lastEntry != null) {
                                        	authorizedTags[i].CurrentDir = lastEntry;
                                        }
                                }

				response.Payload = authorizedTags;
			break;
			case 'GetEntries':
				response.Payload = JSON.parse(fs.readFileSync('entries.json'));
			break;
			default:
				response.Sucess = false;
				response.Error = 'Action not found';
			break;
		}

		ws.send(JSON.stringify(response));
        });
});

http.createServer(function(req, res) {
	//console.log(JSON.stringify(req.headers, null, 2));

	/*res.setHeader('Content-Type', 'text/plain');
	res.setHeader('Access-Control-Allow-Origin', '*');
	res.setHeader('Access-Control-Allow-Headers', '*');*/

	if(req.headers['user-agent'] === 'ESP8266') {
		if(req.headers.chipid !== '962849'
			|| req.headers.rfidtag == null) {
			console.log('Missing RFID tag in request');
			return notAuthorized(res);
		}

		var tag = req.headers.rfidtag.trim();

		var authTag = getTag(tag);

		if(authTag == null) {
			console.log('Tag', tag, 'has not been registered');
			return notRegistered(res);
		}

		var entriesFile = 'entries.json';

		// Create entries file (if it does not exist)

		if(! fs.existsSync(entriesFile)) {
			fs.writeFileSync(entriesFile, "[]");
		}

		// Write entry

		var entries = JSON.parse(fs.readFileSync(entriesFile));

		var lastEntry = lastEntryForTag(entries, authTag);

		var newEntry = {
			TagId: authTag.Id,
			Time: (new Date()).getTime(),
			Dir: lastEntry == null
				? 'IN'
				: (lastEntry.Dir == 'IN' ? 'OUT' : 'IN')
		};

		entries.push(newEntry);

		console.log('--- ', authTag.Name, 'goes', newEntry.Dir);

		fs.writeFileSync(entriesFile, JSON.stringify(entries, null, 2));

		wss.clients.forEach(function each(client) {
      			if (client.readyState === WebSocket.OPEN) {
        			client.send(JSON.stringify({
					Success: true,
					Context: {
						Action: 'TagModified',
					},
					Payload: newEntry
				}));
      			}
    		});
	} /*else {
		if(req.headers.action != null) {
			switch(req.headers.action) {
				case 'GetTags':
					var entries = JSON.parse(fs.readFileSync('entries.json'));
					var authorizedTags = JSON.parse(fs.readFileSync(TAGS_FILE_PATH));

					for(var i in authorizedTags) {
						var lastEntry = lastEntryForTag(entries, authorizedTags[i]);

						if(lastEntry != null) {
							authorizedTags[i].CurrentDir = lastEntry.Dir;
						}
					}

					res.write(JSON.stringify(authorizedTags));
				break;
				default:
					res.write('Undefined action');
				break;
			}
		}
	}*/

	res.statusCode = 200;
	res.statusMessage = "OK";

	res.end();
}).listen(80, '0.0.0.0');

console.log('Server has been started...');
