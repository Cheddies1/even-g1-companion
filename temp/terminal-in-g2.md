## Making a PB&J While AI Coded My Website

I made a peanut butter and jelly

sandwich while I vibe [music] coated my

website. I'm not kidding. I walked into

the kitchen. Can you add some cool

animations? I made lunch. And by the

time I came back, Claude had already

built a full React website for my

YouTube channel. Threw my glasses, no

keyboard, no [music] mouse, no

babysitting a screen. That's what

terminal mode on the Even G2 actually

looks like. And today I'm going to show

you exactly how to set it up step by

step and then show you what it looks

like when it's running. Let's get into

it. [snorts]

## What Is the Even G2?

Hey guys, this is Spencer with Tech with

Spencer and today we're talking about

terminal mode, the newest feature even

realities just pushed in app version

2.2.0.

But first, [music] quick context. In

case you've never heard of the Even G2,

these are smart glasses. [music] And I

don't mean the kind of glasses with

cameras or big chunky displays on the

side. These look like normal glasses.

They're prescription capable. They weigh

almost nothing. And they have a small

microLD display that projects

information directly into your field of

view. Notifications, translation,

teleprompter, all that good stuff. All

visible through the lens. invisible to

everyone else looking at you. If you

want the full picture on what these

glasses are and whether they're worth

it, I've got a complete review on my

YouTube channel. I'll link [music] it in

the description below. But for today,

all you need to know is these are a

discrete heads-up display that sits on

your face like a normal pair of glasses.

## What Terminal Mode Actually Does

[music] Now, let's get into terminal

mode.

Here's the pitch in one sentence.

[music]

your Mac terminal mirrored directly into

your G2 glasses display controlled by

your voice through an AI coding agent

using Claude code. You speak a command,

Claude executes it in your terminal. The

output, the code, the responses, and

[music] the errors, scrolls through your

field of view in your glasses. It's

unbelievable. Your hands do not touch a

keyboard. Even reality's built this

around cla code specifically, and they

went one step further. They created 11

cloud code skills designed to build the

evenhub apps, which means you can use

these glasses to build new apps for your

glasses. [music] I'm telling you, I

should not be as excited as I am about

this. There are so many times when I'm

viating something and I have to walk

away, but I know the coding stops the

first permissions that pop up. This

solves that 100%. Now, even put their

own announcement video on this. [music]

I'll be honest, it's about 2 and 1/2

minutes inside of a 9-minute journal

video. There's no setup walkthrough, and

the demo cuts away before the build

finishes. So, that's what we're doing

here today. The full setup, the full

demo, and [music] the honest verdict on

whether this actually works.

## Setup Overview (Mac Only — Important)

All right, let's set this up, guys. And

I want to flag up front, this is Mac

only right now. even hasn't pushed

Windows or Linux support yet,

unfortunately. If you're not on a Mac,

you're pretty much waiting. Sorry. Okay,

let's go. Step one, install the Claude

## Step 1: Install Claude Code CLI

Code CLI. Go to add even terminal, turn

it on, and add a host. We'll come back

to this in a second. First, on your Mac,

open your terminal and run this command.

This installs the Claude Code CLI

directly onto your machine. Let it run.

## Step 2: Add Claude to Your Path

Step two, add Claude [music] to your

path. Once that finishes, run these two

commands back to back. This command just

makes sure your terminal knows where to

find Claude when you need to call it.

## Step 3: Launch Claude

Step three, launch Claude. Type Claude,

hit [music] enter. It's going to ask you

to trust the current folder. Say yes.

Hit enter. It may also ask you to access

your documents. I allowed it. [music] Up

to you, but you want to make sure it's

able to read your project files. Step

## Step 4: Verify Login

four, check if you're logged in. Type

claude say hello and hit enter. If Cloud

responds, you're good.

If it says you're not logged in, type

forward/lo, that's a forward slash, then

log in. A menu comes up. Select option

one, claude account with subscription.

This opens a browser window where you

can log in, hit authorize, and then

you're back in the terminal. You'll know

it worked when you see the build

something great page.

Once you see that, go back to your

terminal and run Claude say hello again.

If Claude says hello back, you're in.

We're logged into Cloud now. [music]

## Step 5: Install Even Terminal

Step five, install even terminal. Now

leave cloud up in the same terminal

window and run this.

Just a quick heads up, I got a

permissions error when I ran this. If

you do too, just add pseudo to the front

of your command. Pseudo just gives the

installer higher permissions on your

machine.

It'll ask for your password. That's just

your normal Mac login.

When you see adding packages, you're

good.

## Step 6: Connect with Port & Token

Step six, connect [music] even terminal

with your port and your token. This is

the part that connects your glasses to

everything that we just set up. In the

terminal, run this. Breaking that down,

even terminal is the app that we just

installed. The -p 3600 is just a port.

You can really use any port you want. I

just like using 3600. The - T is your O

token. This is what you'll enter in the

even hub app. [music] I'm using 1 2 3 4

5 6 7 8 9. You can set it to whatever

you want. Just keep it consistent. Step

seven, connect your phone. Go back into

## Step 7: Connect Your Phone

your Evenhub app on your phone and go to

the host setup that we saw in the

[music] first step. Tap the top right

corner and scan the QR code that was

created. [music]

It pulls in all of your settings

automatically.

Then add a host name. I just called mine

Spencer MacBook Pro. Hit save.

[music]

And that's it. Setup is done. Total time

## Setup Complete (20 Min Total)

took about 20 minutes. Honestly, less if

you don't hit any permission issues like

I did. [music] Now, let's go actually

use it.

## Demo 1: Build a React Website Hands-Free

[music]

So, the first thing I wanted to test was

something real, not a tiny script,

something I could actually look at and

evaluate. [music] So, I told Claude to

build a website for my Tech with Spencer

YouTube channel. Full React build from

scratch. just using my voice and Claude

just started building it. I could see it

working through the glasses, the file

structures being created, the components

being written, the output scrolling

through my field of view in real time.

And I want to be very transparent about

something here. I really didn't even

give it any guidelines. No design brief,

no specific requirements, just that one

sentence and it just ran with it. When

Claude said it was done, it pointed me

to localhost 5180 to preview the [music]

site. That didn't load. So, I tried

5181. And honestly, for a completely

prompted website with zero guidelines at

all, it did extremely well. Way better

than I expected. [music]

[music]

[music]

[music]

## Demo 2: The Real PB&J Test

Test two, the PB&J test. [music] This is

where the pitch actually becomes real. I

kicked off a longer build, put the

glasses on, and walked to my kitchen,

made a peanut butter and jelly sandwich,

full thing, the bread, the peanut

butter, and the jelly. The entire time I

could see Claude working through my

glasses. Output scrolling, files being

written, I didn't touch my keyboard

once. I just use some subtle prompts to

keep it going.

Can you add some cool animations?

[music]

Can you add a contact me page?

By the time I came back to my desk, it

was done. That's what stop babysitting

your terminal actually means in

practice. And wow, does it work. Long

builds, test run, deployments, anything

where you normally sit there and stare

at your screen waiting, you just don't

have to anymore. You get that time back.

And that's genuinely useful. Even

Reality's markets terminal mode as build

wherever you are. And I'd say that's

accurate but underelling it. The better

framing is your terminal follows you

now. You're not tethered to your desk

for the boring parts of the build.

[music]

Now, voice command accuracy in quiet

## Voice Accuracy — What to Watch Out For

environments. This is clean. Commands

register well. Claude understands

technical instructions and the loop

[music] works. Where you want to be

careful is the precision, though. If

Claude mishars a file path or a variable

name, it goes off in the wrong direction

fast.

Speak clearly and deliberately,

especially for anything technical.

[music]

That's not a knock on the glasses. The

G2 mics are actually really good. It's

just the nature of giving precision

coding instructions by your voice.

You have to adapt to it quickly. That's

the same thing that happened with my

website is it was asking for a URL that

says techpenser, but it added a period

at the end and that threw everything

off. But it's okay. We'll get it.

## Verdict: Who Is This Actually For?

So, where do I actually land on this?

Terminal mode is real and it works. I

said a while back that the GT was

becoming a platform, that this was a

foundational moment. The hardware was

solid, but the ecosystem hadn't fully

arrived yet. Terminal mode is exactly

the kind of update I was talking about.

This is a real new capability, not a

gimmick. Who's this actually for right

now? Developers are already using Claude

Code who own a G2 and want to extend

their workflow beyond the desk. If

that's you, update to V2.2.0 tonight and

run through the setup. It's free. It's

already on your device and in 20 minutes

it gets you [music] there. Who should

## Who Should Wait?

wait? If you don't have a G2 yet or

you're thinking about buying it

specifically for terminal mode, I'd pump

the brakes a little bit. To be fair,

even is moving extremely fast. They ship

Conversate 2.0, even [music] hub, and

now terminal mode in such a short

window. The rough edges are still there,

but the direction is clear and [music] I

think they know exactly what they're

building. I'm going to keep testing

this. anything changes, better mic

processing, Windows support, or a

meaningful firmware update, I'll report

back. If you've already tried terminal

mode on your G2, drop a comment. I want

to know exactly what you built and what

you ran into. I'll prioritize those

questions for a follow-up video. And if

you want real, honest world tech reviews

that focus on how things actually fit

into your daily life, consider

subscribing. That's exactly what this

channel is. Thanks for watching and I'll

see you in the next



FULL SETUP (CLAUDE + EVEN TERMINAL)
Install Claude Code CLI
Open Terminal and paste this command:
curl -fsSL [https://claude.ai/install.sh](https://www.youtube.com/redirect?event=video_description&redir_token=QUFFLUhqbEVPUDF6SmdEQW5SUmgtSVlMcVhRUFBiWlNjQXxBQ3Jtc0ttdTFmZ3VPdWZMcG54RWwza012ZEl5eHdDMzBkMlkzV2hwbm1vLUVXaUxtamVETU9VbVRZcVR3ZWYxZWtmRy1LTTE0cmJReFlYeXA1X1hKRHJXbGtzWWpHQXQzelJzZlZ4RkF3QTc2OENOZW1NdzFXMA&q=https%3A%2F%2Fclaude.ai%2Finstall.sh&v=K2_HZB_KXdU) | bash
Then run these two commands:
echo 'export PATH="$HOME/.local/bin:$PATH"' ~/.zshrc
source ~/.zshrc
---

Now start Claude by typing:
claude
• Trust the folder when prompted
• Allow permissions if asked
Test it by typing:
claude "say hello"
If you're not logged in, type:
/login
Then:
• Choose Claude account with subscription
• Login in browser and click authorize
If you see "build something great" you're good to go.
Install Even Terminal
Run this command:
npm install -g @evenrealities/even-terminal
If you get a permissions error, run:
sudo npm install -g @evenrealities/even-terminal
(It will ask for your computer password)
Start Even Terminal Host
Run this command:
even-terminal -p 3600 -t 123456789
Explanation:
-p is the port (you can change this)
-t is the auth token (you will use this in Even Hub)
Connect in Even Hub
• Go to Even Hub → Add Even Terminal
• Scan the QR code from your terminal
• Add a host name (example: Spencer MacBook Pro)
WHY THIS MATTERS
This is where smart glasses start shifting from content consumption to real interaction.
Instead of just watching a screen, you’re now running AI tools directly in your field of view.
QUESTIONS
Would you actually use something like this every day…
or is this still too early?
SUPPORT THE CHANNEL
If you want real-world testing on smart glasses, AI tools, and wearable tech — subscribe.
I’m pushing these devices to their limits so you don’t have to.
ABOUT THE CHANNEL
On Tech With Spencer, I break down smart glasses, wearable tech, and real-world technology — no hype, no fluff.
I focus on:
• Smart glasses and AR
• AI tools and real-world use
• Practical tech that actually matters
• What’s coming next
