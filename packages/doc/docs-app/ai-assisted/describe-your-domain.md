---
title: Describing Your Domain
sidebar_position: 3
---

# How to Describe Your Domain

The better you describe your domain, the better the generated code. Here's what the AI needs to know.

## 1. Bounded Contexts (Plugins)

What are the major areas of your system?

> "The system has a Catalog for managing products, an Ordering system for customer orders, and a Shipping system for delivery tracking."

Each becomes a Reventless **plugin**.

## 2. Entities

What are the main domain objects in each context?

> "The Catalog has Products and Categories. Ordering has Customers and Orders."

## 3. Commands (What Users Do)

For each entity, what actions can users perform?

> "Products can be added, renamed, have their price changed, and be archived."

Use **imperative verbs**: add, create, update, change, remove, place, ship, cancel.

## 4. Events (What Gets Recorded)

Usually derived automatically from commands. Mention explicitly if events differ from commands:

> "When a product is added, we record its full details. When the price changes, we only record the new price."

## 5. Error Conditions

What can go wrong?

> "Adding a product that already exists should fail. Updating a non-existent product should fail."

## 6. Queries (What Users See)

What views do users need?

> "Users need a list of all products with name and price. A detail view showing full product info."

## 7. Cross-Plugin Communication

Which plugins need events from other plugins?

> "Ordering needs to know about available products from the Catalog. The Catalog needs to track demand from Ordering."

This creates **extension points** (publisher) and **extensions** (subscriber).

## 8. Side Effects and Automation

External system calls, emails, automated workflows:

> "When an order is placed, send a confirmation email. Auto-ship orders after 24 hours unless cancelled. Import products from a supplier CSV feed."

These map to:
- Email/API calls → **OutboundTranslationSlice**
- Automated workflows → **AutomationSlice**
- External data imports → **InboundTranslationSlice**

## Example: Complete Description

> "Create an online shop with two plugins:
>
> **Catalog** (DCB): Products can be added, renamed, repriced, and archived. Categories can be created, renamed, and archived. Import products from a supplier feed. Expose product availability and price changes to other plugins.
>
> **Ordering** (DCB): Customers can register and update their email. Orders can be placed with multiple line items, shipped, and cancelled. When an order is placed, send a confirmation email. Auto-ship orders after 24 hours unless cancelled. Subscribe to Catalog's product availability events."
