# WeatherForecastProcessing
# Get the weather information from various sources as defined in the settings file.
# I used a settings file simply because it was easy.  This data could come from a database or a call from a web front end or wherever we want
# Currently this supports the following formats/sources
# US National Weather Service - flat file and API call
# NOAA National Digital Forecast Database (NDFD) - file only.  API calls could be added later

# TODO: Better error handling.  We should be able to have an error with reading a file or an API call and still process the rest of the requested data but it needs to be more robust
