# Cover Calendar

A KOReader plugin that shows your reading history as a monthly calendar with book cover thumbnails, plus a yearly overview of everything you've read.

Compatible with SimpleUI — the plugin registers as a Quick Action

## Features

### Monthly calendar
* A flat, cover-first, calendar design  fully Inspired by u/ReadinGadgets
* Tap any day to see book details: title, author, series, reading time, pages read, and progress percentage
* If you read multiple books in one day, use the arrow buttons in the popup to browse between them
* Optional reading time badge on each cell
* **Today** button jumps back to the current month, shown only when you've navigated away
* Arrows in the top left move between months; swiping works too

### Yearly overview
* A **Year** button opens twelve month rows showing the covers of every book you finished
* Switch between all 12 months and 6 months at a time — the 6-month view gives you noticeably bigger covers
* Arrows in the top left page through months and roll across year boundaries
* Tap any month row to jump straight to that month's calendar

### Finished / Read modes
* A toggle in the yearly overview switches the rows between books you **finished** that month and everything you **read** that month
* Read mode lists a book in every month it was actually read, so a long book spanning three months shows up in all three
* Set the minimum time a book must be read within a month to qualify in Settings — 5 minutes, 30 minutes or 1 hour

### Configurable stats
Both the monthly header and the yearly overview show three stat slots you choose yourself:

* Books finished
* Books read
* Pages
* Pages/day
* Time read (hours+minutes or days+hours)
* Average minutes/day
* Days active
* Current streak
* Longest streak

## Installation

1. Download `covercalendar.koplugin.zip` from the Releases page
2. Extract the zip to get a folder called `covercalendar.koplugin`
3. Copy the folder to `.adds/koreader/plugins/` on your Kobo
4. Restart KOReader

## Opening the plugin

By default, you'll find it under **Tools → Cover Calendar → Open Cover Calendar**.

For quicker access, you can assign it as a Quick Action — what I've done is add it to the bottom navigation bar in SimpleUI, where it appears as *Open Cover Calendar* under System Actions.

## Requirements

Requires KOReader's **Statistics** plugin to be enabled, since that's where the reading history comes from. Covers are read from KOReader's own book info cache, so no extra setup is needed.

---
