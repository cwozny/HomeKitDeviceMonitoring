# Home Sensors requirements

This document lists the requirements for Home Sensors. It records the capabilities that the project owner asked for, without design or implementation details. The current software meets each requirement.

## Conventions

Each requirement uses "shall". A sentence without "shall" gives a definition, a fact, or context.

## Terms

| Term | Meaning |
|---|---|
| Device | A sensor or other smart-home device in the home. |
| Reading | One value that a device reports, for example a temperature. The battery level is not a reading. |
| Web page | The dashboard as a web browser shows it. |

## Device data

- **DATA-1** The software shall only read data. It shall not change a device.

## Dashboard

- **DASH-1** The dashboard shall show the battery level and the readings of every device in the home that reports them.
- **DASH-2** The dashboard shall show the last time that the software received data from the devices.
- **DASH-3** A viewer shall be able to sort the devices by battery state, with the lowest battery first.

## Web page

- **WEB-1** A web browser on a phone shall be able to show the dashboard.
- **WEB-2** The web page shall be available at all times.
- **WEB-3** The web page shall show new data without a request from the viewer.
- **WEB-4** The web page shall show the Git commit of the software that runs.

## History

- **HIST-1** The web page shall have a separate view with a chart of the battery level and of each numeric reading of each device, for the last 7 days.
- **HIST-2** The same view shall show the daily low and high of each numeric reading of each device, for the last 7 days.
- **HIST-3** If the software stops and starts again, the history shall stay.

## Security and privacy

- **SEC-1** The web page shall be read-only.
- **SEC-2** Other websites shall not be able to read the dashboard data through the browser of a viewer.
