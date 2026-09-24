# Phase 3 trials: read these aloud, one at a time, leaving about two seconds between them

Start `jev-cua run` (or open JevCUA.app), note the run folder name, then read. Say each line naturally.
For 'stop' lines, say the first part, pause half a second, then the stop word. Afterwards:
`scripts/jev-cua trials runs/<ts>`.

 1. **open the notes app**  → expect open_app
 2. **create a new note**  → expect new_note
 3. **make the title say hello**  → expect type_text
 4. **open chrome**  → expect open_app
 5. **google search norbert wiener**  → expect web_search
 6. **open x dot com**  → expect open_site
 7. **take a picture of me**  → expect take_photo
 8. **open the notes app and create a new note**  → expect open_app, new_note
 9. **open chrome and go to wikipedia**  → expect open_app, open_site
10. **launch photo booth**  → expect open_app
11. **switch to chrome**  → expect open_app
12. **bring up the notes app**  → expect open_app
13. **search for alan turing**  → expect web_search
14. **look up the weather in san diego**  → expect web_search
15. **go to github**  → expect open_site
16. **open youtube**  → expect open_site
17. **scroll down**  → expect scroll_down
18. **scroll down a bit**  → expect scroll_down
19. **scroll up**  → expect scroll_up
20. **go back**  → expect go_back
21. **press escape**  → expect press_escape
22. **type good morning**  · _with a text field focused_  → expect type_text
23. **snap a photo**  → expect take_photo
24. **new note**  → expect new_note
25. **open safari**  → expect open_app
26. **open system settings**  → expect open_app
27. **send the message**  → nothing
28. **cancel**  → nothing
29. **send the message**  → nothing
30. **confirm**  → expect press_enter
31. **the weather is nice today**  → nothing
32. **I was thinking about opening a bakery**  → nothing
33. **don't open chrome**  → nothing
34. **my friend told me to search for a new apartment**  → nothing
35. **she said take a picture of the sunset**  → nothing
36. **notes are useful for remembering things**  → nothing
37. **let me think about what to do next**  → nothing
38. **the google results were interesting**  → nothing
39. **scrolling through the feed is a waste of time**  → nothing
40. **what else is there**  → nothing
41. **google search ... stop**  · _say 'google search', pause half a second, then 'stop'_  → nothing
42. **make the title say ... stop**  · _say 'make the title say', pause, then 'stop'_  → nothing
43. **open the ... never mind**  · _say 'open the', pause, then 'never mind'_  → nothing
44. **open chrome so I can check my email**  → expect open_app
45. **open the notes app because I need to write something down**  → expect open_app
46. **make the title say salt and pepper**  · _with a note body focused; payload 'salt and pepper'_  → expect type_text
47. **google search cats and dogs**  → expect web_search
48. **click new note**  · _either is acceptable_  → expect new_note, click_element
49. **open chrome**  → expect open_app
50. **scroll to the bottom**  → expect scroll_down
