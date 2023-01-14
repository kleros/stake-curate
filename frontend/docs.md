# Frontend

## Screens

### Home

`/`

Looks like a landing page. Showcases some stats, like how much value has been staked, etc.
Provides a button that links to The List, which is a list of lists intended to act as the frontdoor of the application.

### List View

`/list/4`

Contains panels as described below. Panels can be collapsed and expanded.

**Basic Info Panel**: Renders some basic information about the List: Name, description, link to the policy, minimum amount (both in tokens and value) to submit items.
It shows you the *challenge types* there are accepted for removing items in this registry. A challenge type contains a title, a short description, a ratio (the % of the item stake the challenger will obtain as reward), and should be clarified in the List Policy. If the List doesn't enable this setting, then this stays hidden. (This means, there's only 1 challenge type of "Incorrect Item", that takes 100% of the item stake as a reward.) It also features a button that spawns a **➕ Create Item** modal.

**Create Item Modal**: This is a form, for the user to fill. Query parameters can be used to prefill these fields (e.g. `/list/4?mode=submit&name=Dorothy`) which is useful to integrate faster with other apps. Every field corresponds to a row. They contain the field name, a field description you can read by hovering, and an input field. To the right, there's some extra space to fit a ✔️ or ❌.

According to the field types, the form will render errors if incorrect data is put in. Unless all mandatory fields are correctly filled, the "Submit" button will stay greyed out.

If the user does not have a Stake Curate account, or their account does not possess enough stake (in both value for the arbitration fees, and tokens for the challengers), then the "Submit" button takes a different shape. It shows you how much value and tokens you need to stake in order to be able to submit. Note tokens may need to be approved separately.

```
If not enough value   If not enough tokens

┌──────────────────┐  ┌───────────────────┐
│                  │  │                   │
│ Deposit 0.3 ETH  │  │ Deposit 100 DAI   │
│                  │  │                   │
└──────────────────┘  └───────────────────┘

If neither            If enough

┌──────────────────┐  ┌───────────────────┐
│                  │  │                   │
│ 0.2 ETH + 100 DAI│  │ Submit <itemname> │
│                  │  │                   │
└──────────────────┘  └───────────────────┘
```

Advanced users may want to make this item stake be higher, in order to get punish griefers and get greater compensations from the damages they may cause, but I don't know how to provide this option in a simple way.


**Items Panel**: It shows you the items that were submitted to this list. There is a bunch of filters, examples: Included, Challengeable, Removed, Outdated... . Included is the filter that's enabled by default.
For each item, it shows the properties of the latest edition. They are pruned or omitted if they need to, in order to fit. Clicking on an item directs to Item View.
In this view, if an item is challengeable, you can see how many tokens could you get by challenging and winning.
In case the List is a List of Lists, the Item instead provides a button to open the list, but it can still be clicked to check its details like any other Item.

### Item View

`/item/52`

Detail of an item.

**Basic Info Panel**: How much value could you get by challenging and winning. If the item has had multiple editions, here you can click to select them. The last edition is the one selected by default.
If the item is challengeable, at the bottom, you can see how many tokens could you get by challenging and winning, and a Challenge button will be rendered in the Edition Panel.

**Edition Panel**: The properties of the edition. They could be rendered in a table format, name of the field, and value of the field. They can be of many types, such as string, number, address, image, url...

If there are incorrect fields, that is, fields that do not correspond with the list version contemporary to the edition, a warning is shown besides them. This is in the form of a red warning sign, to the left of the field name. Hovering over the warning sign tells you the reason.
> Field 'Field' is unknown.

If there are mandatory missing fields, show a warning at the top of the edition. On hover, show the missing fields.
> Field(s) 'Field1', Field2' are missing.

If there are validation errors for existing fields, warn on them as well with a yellow warning sign, and show the validation error.
> Address cannot contain character 'p'.

Buttons may be shown in the top right corner: a "♻️ Refresh" button, an "✏️ Edit" button, and a "🚩 Challenge" button.

Refresh simply calls the function `refreshItem`. For simple users, this should only show if the item has been Removed, Retracted, is Outdated, Uncollateralized, etc. Advanced users may want to use this to raise the stakes, so they would need to be able to input token amounts.

**Editing**

This button shows at all times, even if the item was Removed, or even if the Item is currently challenged.

Clicking on it will open up a modal. It will automatically hide incorrect fields from view. It starts with the previous values prefilled by default. It will render unfilled, optional fields as well. There is a "Next" button below, that will be greyed out until all mandatory fields are properly filled in without errors. Query parameters can be used to prefill an edit (`/item/52?mode=edit&name=Mark`).

Clicking "Next" will let you see the changes, it will only show what fields have changed. If circumstances make it so that the account requires staking more value and tokens in order to take ownership of the item, the button is replaced by a staking button. If already enough, you can click "Confirm Edit" to finally Edit the item. Just like with Refresh, advanced users may want to use this to raise the stakes. But let's implement the UX support when it's actually needed.

**Challenge**: It will open up a modal. The required stakes to challenge the item are shown. They are expressed in ETH and in the needed ERC20 tokens.

Example:

```
 Write your reason below...     (c.type)     (reward)
┌──────────────────────────┐   ┌────────┬──┬───────────┐
│this user started spamming│   │Spam    │ |│500 DAI    │
│the group and here's the  │   │100%    │ v│           │
│evidence: link.net/proof  │   └────────┴──┴───────────┘
│                          │    You will need...
│it satisfies the criteria │   ┌───────────────────────┐
│of "posting unrelated,    │   │0.1 ETH   +  300 DAI   │
│commercial references..." │   │                       │
│        (...)             │   │  [Challenge]          │
└──────────────────────────┘   └───────────────────────┘

                                  (challenger stake)
```

The % of the item stake that will be awarded for a successful challenge shows at the left of the Challenge Type, both when selected and when viewed in the selector list.

- if not enough funds for challenging, the button will gray out and a warning will appear at the top of the modal, to warn the user before they spend time typing in a reason.
- if enough funds but not enough allowance, the button will first approve the required tokens.

At the contract level, advanced challengers could opt to send greater token and value amounts, to obfuscate their commits. But, this is very advanced and could be delayed or, never added.

Query parameters can be used to prefill a challenge (`/item/52?mode=challenge&type=2&reason=abcdefg`).

When finally challenging, the frontend will create a salt, hash some parameters, and guide the user towards committing the challenge. The information related to the challenge will be stored locally.

After **committing** the challenge, a certain amount of time will pass, and then the user will be able to reveal their challenge. a timer countdown will show up in the "Reveal" button. "Reveal in 1m 53s". After this timer passes, the user can click on "Reveal".

When the user **reveals**, the arguments they hashed are passed as argument.

**Dispute Panel**: Shows if the Item is Disputed, and since when has it been Disputed. Links to an application better suited to handle this. (With Kleros V2, I'm not sure how much information is available to consume from the Arbitrable.)  

**Evidence Panel**: History of evidence published on this item. This can work as any other arbitrable frontend.

## Create / Edit / Refresh `itemStake` common behaviour

These functions require the user to hold a certain amount of tokens and value in their account. They share some behaviour.

- If funds in the user's wallet + funds in the user's account are below minimum, a warning will appear over the top. The user will not be prevented from trying out the forms, if they exist, but they won't be able to send any transaction, as the button to continue will be grayed out.

- They all can customize the stake that will be collateralizing the item, as long as it is below the maximum offered by the list. To customize, you click on a toggle that allows you to type an amount of tokens. It defaults to minimum, on toggle.
  - If choosing an amount below minimum, the button will turn red and unpressable. "Item stake under minimum". A shortcut must be offered to the user to set stake to minimum, instead.
  - If the user offers more than the maximum, the button will turn red, and unpressable. "Item stake over threshold". A shortcut must be offered to the user to set stake to maximum, instead.
  - If choosing an amount that is over their means, it will prevent them from continuing. "Insufficient Balance". A shortcut may be offered to the user to set the maximum amount within their means.

- If there are not enough funds in the user's account but the wallet holds enough, the button that will commit the action will ask them to fund first. Funding can use tokens as well, so if the amount of extra tokens to submit is non-zero, allowance is checked, and if not enough, approval will be done first, either manually or with EIP-2612.

## TODO

- creating lists
- editing lists, by the list governor
- retracting items, when you're the owner
- withdrawing funds from your account
- toggle for "auto-reveal"?
- explain outbidding in `itemStake`
- reconsider if modals should stay or be replaced
