@echo off
hac --ip %HASS_IP% --port %HASS_PORT% --api-token %HASS_TOKEN% call light toggle --service-data "{""entity_id"": ""%1""}"