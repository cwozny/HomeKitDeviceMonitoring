# Home Sensors requirements

This document lists the requirements for Home Sensors. It records the capabilities that the project owner asked for. The current code meets each requirement, except the items in [Open items](#open-items).

## Conventions

Each requirement uses "shall". A sentence without "shall" gives a definition, a fact, or context.

## Terms

| Term | Meaning |
|---|---|
| Device | A HomeKit accessory. |
| Reading | One value that a device reports, for example a temperature or a battery level. |
| Refresh | A read of all tracked values from HomeKit. |
| Host Mac | The Mac that runs the app all the time and serves the web page. |
| Web page | The dashboard that the host Mac serves to browsers. |

## Data from HomeKit

- **DATA-1** The app shall get device data from Apple HomeKit through the HomeKit framework.
- **DATA-2** The app shall show each device that reports a battery level or a sensor reading. This includes devices from all manufacturers.
- **DATA-3** The app shall support Matter devices on a Thread network that are in the Home app. These devices need a home hub, for example an Apple TV.
- **DATA-4** The app shall only read from HomeKit. It shall not change a device.
- **DATA-5** The app shall turn on change notifications. Then HomeKit sends each change to the app at the time that it occurs.
- **DATA-6** When the app starts, it shall read all values. When a device comes back online, or someone adds a device to the home, the app shall read that device.
- **DATA-7** The app shall do a refresh every 15 minutes as a safety net. [OPEN-1](#open-items) can change this requirement.

## Dashboard

These requirements apply to the app and to the web page.

- **DASH-1** For each device, the dashboard shall show the name, the room, the model, the battery level, and the readings.
- **DASH-2** The dashboard shall show temperature, humidity, motion, occupancy, contact, water leak, and smoke readings. It shall also show carbon monoxide, carbon dioxide, air quality, PM2.5, PM10, VOC (volatile organic compounds), and light level readings.
- **DASH-3** If a device reports a fault or a tamper state, the dashboard shall show it. If not, the dashboard shall not show these states.
- **DASH-4** The dashboard shall show a battery level as a percentage. If a device reports only a low-battery flag, the dashboard shall show "Low" or "OK". If a device reports neither, the dashboard shall show "—".
- **DASH-5** The dashboard shall treat a battery level of 20% or less as low, and 10% or less as critical.
- **DASH-6** If a device does not respond, the dashboard shall show "Not responding" for that device.
- **DASH-7** The dashboard shall show four summary tiles. The tiles shall show the number of devices, the devices with a low battery, the devices that do not respond, and the lowest battery level.
- **DASH-8** The dashboard shall group devices by room. It shall also have a list of all devices, with the lowest battery first.
- **DASH-9** A status color shall always have an icon and a text label with it.
- **DASH-10** The dashboard shall support light mode and dark mode.
- **DASH-11** The "Updated" time shall show the last time that the app got data from HomeKit. Data from HomeKit is a change that HomeKit sent, or a read that succeeded.

## App

- **APP-1** The app shall run on Mac (Mac Catalyst), iPhone, and iPad. Only the Mac app serves the web page.
- **APP-2** On a Mac, the window shall be resizable. Its minimum size shall be 760 × 480 points.
- **APP-3** When the app launches, it shall start HomeKit and the web server. It shall not wait for its window to open.
- **APP-4** The Refresh button in the app shall do a refresh at most once a minute. When the app comes to the front, it shall do a refresh with the same limit. [OPEN-1](#open-items) can change this requirement.

## Web page

- **WEB-1** The Mac app shall serve the dashboard as a web page. Browsers on phones and computers on the home network shall be able to open it.
- **WEB-2** Phones and computers on the same Tailscale network shall also be able to open the web page.
- **WEB-3** The web server shall listen on all network interfaces. The default port shall be 8080.
- **WEB-4** The `WebServerPort` setting shall change the port. The app shall accept the setting from `defaults write` or from the `-WebServerPort` launch argument.
- **WEB-5** The app shall show the address of the web page. The address shall use the host name of the Mac.
- **WEB-6** The web page shall show the same summary tiles and devices as the app. It shall have three views: Room, Battery level, and History.
- **WEB-7** The web page shall remember the last view that the viewer selected.
- **WEB-8** The web page shall work at the width of a phone. A phone shall be able to add the web page to its Home Screen.
- **WEB-9** The web page shall get new data from the app every 15 seconds. It shall not have a Refresh button.
- **WEB-10** If the web page cannot get data from the app, it shall show a message. It shall also keep the last data that it got, dimmed.
- **WEB-11** A footer shall show the app version and the short Git commit SHA of the build. If the build had uncommitted changes, the footer shall say so.
- **WEB-12** If the web server cannot listen, the app shall try again every 30 seconds. For example, another app can use the port.

## History

- **HIST-1** The web page shall have a History view. This view shall show a chart for each numeric reading of each device, for the last 7 days.
- **HIST-2** HomeKit keeps no history. Thus, the app shall record the readings itself.
- **HIST-3** The app shall record a changed value at most once a minute. It shall record an unchanged value every 10 minutes.
- **HIST-4** If a device does not respond, the app shall not record its readings.
- **HIST-5** The app shall save each reading to disk at the time that it records the reading. It shall keep 7 days of readings.
- **HIST-6** If the app quits, crashes, or restarts, the history shall stay. If someone installs a new version of the app, the history shall also stay.
- **HIST-7** If the history file has a damaged line, the app shall ignore that line and continue.
- **HIST-8** Each point on a chart shall be the average of a 10-minute period. The periods shall align with the clock.
- **HIST-9** Each chart shall show the current value and the low and high values. Where data is missing, the line shall have a gap.
- **HIST-10** A viewer shall be able to read the value at a given time with touch, a mouse, or the keyboard.
- **HIST-11** Each chart shall have a table of the low, high, and average values for each day.
- **HIST-12** Temperatures shall use the unit for the region of the host Mac.

## Hosting

- **HOST-1** The app shall run on a Mac that is always on and connected to the home network. The Apple ID on the host Mac shall be a member of the home.
- **HOST-2** On the host Mac, the app shall start at login. If the app quits, it shall open again. A launch agent outside this repository does these tasks.
- **HOST-3** HomeKit access needs the HomeKit entitlement. Thus, the developer shall sign the app with a development profile that includes the host Mac.
- **HOST-4** At the first start, a person at the host Mac shall allow HomeKit access and incoming connections.

## Security and privacy

- **SEC-1** The web page shall be read-only. A request shall not be able to change a device, write a file, or run a command.
- **SEC-2** The web server shall answer only requests that are addressed to the host Mac. It shall accept IP addresses, `localhost`, `.local` names, Tailscale names, names without a dot, and the host name that the app shows. This check prevents DNS rebinding.
- **SEC-3** The web server shall accept only GET and HEAD requests. For other methods, it shall send 405 with an Allow header.
- **SEC-4** If a client does not send its request in 10 seconds, the web server shall close the connection. If a client does not get the response in 120 seconds, the web server shall also close the connection.
- **SEC-5** The web server shall read only the request line and the Host header. It shall ignore request bodies.
- **SEC-6** The public repository shall not contain personal details. Examples are host names, IP addresses, email addresses, device IDs, the developer team ID, and room or device names from a real home.
- **SEC-7** The team ID and the bundle identifier of each developer shall be in `Support/Local.xcconfig`. Git ignores this file.

## Code and process

- **DEV-1** The code shall use Allman braces, also for closures. Each `if`, `else`, `for`, `while`, and `do` shall have braces. The indent shall be two spaces, without tabs.
- **DEV-2** The unit tests shall use Swift Testing, in the `HomeSensorsTests` target. They run with ⌘U in Xcode or with `xcodebuild test`.
- **DEV-3** The tests shall run without HomeKit. When the tests run, the app shall not start HomeKit or the web server.
- **DEV-4** Each signed Mac build shall copy the app into the project folder. iOS builds, unsigned builds, and test builds shall not replace that copy.
- **DEV-5** Each build shall record its Git commit SHA, and whether it had uncommitted changes.
- **DEV-6** Version 1.0 shall have the Git tag `v1.0`.

## Open items

- **OPEN-1** Routine reads from HomeKit. HomeKit sends each change to the app, so the project owner suggested that the app not poll HomeKit. In the proposal, the app has no Refresh button. When the app comes to the front, it does no refresh. The 15-minute refresh runs only after 15 minutes without data from HomeKit. This decision is open.
- **OPEN-2** HomeKit without a window. When the app launches, it starts HomeKit. There is no test yet of HomeKit with an app that has no window.
